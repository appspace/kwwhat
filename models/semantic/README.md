# Semantic models and metrics

Use the dbt Semantic Layer for governed charging reliability and driver growth accounting. 
Definitions live in `semantic_models.yml` and reference marts
only. The file uses the supported legacy YAML format with separate semantic models,
measures, and metrics.

Start with the project definitions for the Charger, Port,
Connector, charge attempt, and visit terminology. Reliability is measured at Port grain;
a visit can span several ports, while driver activity is network-wide.

## Choose the right semantic model

| Semantic model | Mart and grain | Use it for | Default metric time |
| --- | --- | --- | --- |
| `visits` | `fact_visits`: one driver stop at a location | Visit outcomes, retry effort, and attempts belonging to visits | `visit_end_ts` |
| `charge_attempts` | `fact_charge_attempts`: one charge attempt | Attempt-level success, transaction, energy, and error attributes | `charge_attempt_start_ts` |
| `uptime` | `fact_uptime_daily`: one Port per commissioned day | Headline duration-weighted uptime and total downtime | `date_id` |
| `downtime_daily` | `fact_downtime_daily`: one Port, day, and outage | Explain downtime by OFFLINE/FAULTED, reason, and resolved error code | `date_id` |
| `driver_activity` | `fact_driver_activity_daily`: one identified driver per active date | Distinct active drivers and overlapping-window growth accounting | `date_id` |
| `drivers` | `dim_drivers`: one observed credential plus UNKNOWN | First-seen acquisitions and current driver attributes, not activity history | `first_seen_ts` |
| `chargers` | `dim_chargers`: one Charger | Current commissioning state and current location | No measures |
| `ports` | `dim_ports`: one Charger + Port | Port identity and its Charger relationship | No measures |
| `connectors` | `dim_connectors`: one Charger + Port + Connector | Connector type and latest reported operational status | No measures |
| `locations` | `dim_locations`: one location | Conformed location identity | No measures |
| `error_codes` | `dim_error_codes`: one taxonomy + code + name | Decode protocol/vendor errors without mixing taxonomies | No measures |
| `chargex_mrec_attributes` | `dim_chargex_mrec_attributes`: one ChargeX code | ChargeX responsibility and functional-category flags | No measures |

`dim_dates` supplies the daily MetricFlow time spine. `fact_interval_data` and
`fact_location_capacity` are supporting marts, not semantic models in this file. Their
existence does not imply that energy-utilisation or inventory-count metrics are published.

## Visit outcomes and retry effort

| Metric | Definition |
| --- | --- |
| `total_visits` | All visits, including unidentified visits |
| `total_successful_visits` | Visits whose last charge attempt was successful |
| `total_charge_attempts` | Sum of attempt counts on visits, attributed to visit end time |
| `average_attempts_per_visit` | `total_charge_attempts / total_visits` |
| `first_attempt_success` | Successful visits with exactly one attempt |
| `troubled_success` | Successful visits with more than one attempt |
| `failed_visits` | Visits whose last attempt was unsuccessful |
| `first_attempt_success_rate` | `first_attempt_success / total_visits` |
| `troubled_success_rate` | `troubled_success / total_visits` |
| `failed_rate` | `failed_visits / total_visits` |

The three outcome categories partition visits. First-attempt success is the existing
single-attempt-success definition, not a separate assertion about the first attempt of
every multi-attempt visit. Visit success uses the last attempt's authoritative mart flag.
Charge-attempt success depends on the configured `success_energy_threshold_kwh` (default
0.1 kWh), a transaction, a non-Faulted ending status, and a supported stop reason.

`total_charge_attempts` remains a visit-based metric. It is not a count of all attempt
starts on `charge_attempt_start_ts`. The `charge_attempts` semantic model defines additional
attempt-level measures, but these are not independently published metrics here.

## Uptime and downtime

| Metric | Definition |
| --- | --- |
| `uptime_ratio` | `total_uptime_minutes / total_commissioned_minutes` |
| `total_commissioned_minutes` | Sum of commissioned Port minutes |
| `total_uptime_minutes` | Sum of commissioned minutes not lost to outages |
| `total_downtime_minutes` | Port-day OFFLINE + FAULTED minutes, from the uptime model |
| `total_downtime_minutes_detailed` | Outage-level downtime minutes for diagnosis by type, reason, and error code |

Use `uptime_ratio` for the headline reliability number. It weights partial commissioning
days by duration and rolls up across ports, locations, and dates; do not average daily
ratios. A zero commissioned-time denominator has no defined uptime ratio.

Use `total_downtime_minutes_detailed` to explain downtime, not as an additional downtime
quantity to add to `total_downtime_minutes`. The two totals should reconcile for aligned
scope and processing coverage. OFFLINE means no heartbeat; FAULTED means the Port reported
a fault. An outage's resolved error code and a Connector's latest error are different
historical/current-state attributions.

## Driver activity and growth accounting

A driver is active when at least one identified charge attempt **stops** in the reporting
window, successful or unsuccessful. Use non-null `charge_attempt_stop_ts`; open attempts
do not establish lifecycle activity. Identity is the observed `id_tag` credential, not a
resolved human. Null and reserved unknown credentials are excluded from driver metrics.
`dim_drivers.first_seen_ts` / `last_seen_ts` are earliest/latest observed attempt stops;
authorization attributes follow stop ordering. Daily activity uses the stop's date.

| Metric | Meaning on as-of date D |
| --- | --- |
| `active_drivers_7d` | Distinct drivers with a stop on D-6 through D inclusive |
| `active_drivers_30d` | Distinct drivers with a stop on D-29 through D; fixed 30 days, not a calendar month |
| `new_drivers` | Drivers whose first-ever observed stop is on D, shared by both window sizes |
| `retained_drivers_7d` / `retained_drivers_30d` | Drivers in both today's and yesterday's corresponding rolling active sets |
| `resurrected_drivers_7d` / `resurrected_drivers_30d` | Drivers entering today's set after absence from yesterday's, excluding first-ever drivers |
| `churned_drivers_7d` / `churned_drivers_30d` | Drivers in yesterday's set who have aged out of today's |

Retained does not require another stop on D. Churned is window expiry, not permanent loss.
New counts first stops on D, not all acquisitions within the trailing window. First-ever
means first observed in available history. First/last seen cannot reconstruct historical
active sets; current authorization attributes are Type 1, not historical snapshots.
Network-wide activity has no location/Port grain, so local new/retention metrics are not
defined by these published metrics.

The `driver_activity_union_8d` and `driver_activity_union_31d` helpers count the union of
today's and yesterday's rolling sets. They are accounting helpers, not headline KPIs:

- active = new + retained + resurrected
- change in active = new + resurrected - churned

Query `metric_time__day` with an explicit date range and completed, fully ingested dates.
Preserve enough prehistory for the 8/31-day union; initial boundaries are warm-up. Filter
metric time, not activity date, to preserve lookback. Do not sum daily distinct active or
retained counts. Coarser active queries select the last daily snapshot; growth-accounting
identities are daily only. Metric values are not automatically capped to source coverage.

The stop-time migration changes historical dates and requires rebuilding
`int_driver_aggregates` and `fact_driver_activity_daily`, then refreshing `dim_drivers`,
with aligned source/update coverage. An ordinary merge retains old start minima and
obsolete start-date driver-days. Check bounded processing windows and catch up before
exposing results. See [ADR 0014](../../docs/adr/0014-stop-based-driver-lifecycle.md).

### MAD lifecycle stack

MAD uses a **fixed trailing 30 days**, not a calendar month. On D, compare D-29..D with
D-30..D-1, using stopped attempts:

| Metric | Daily classification |
| --- | --- |
| `mad_new` | First-ever observed stop on D |
| `mad_retained` | Active in both windows, whether or not another attempt stops on D |
| `mad_resurrected` | Active in the current window only, first stop before D |
| `mad_churned` | Active in the previous window only; last stop on D-30 |
| `mad_stale` | First stop by D, active in neither window; last stop before D-30 |

The five categories partition identified credentials first observed by D; future first
stops are excluded. `drivers_observed_to_date` is an all-time cumulative acquisition
helper, not today's dimension row count.

- `mad = mad_new + mad_retained + mad_resurrected`
- `drivers_observed_to_date = mad_new + mad_retained + mad_resurrected + mad_churned + mad_stale`
- `mad_stale = drivers_observed_to_date - driver_activity_union_31d`

For a daily lifecycle stack, plot the five positive categories. New/retained/resurrected
are active; churned/stale are inactive. Use just the three active categories for a MAD
stack. Do not add MAD as a sixth category, which double-counts the active population.

New means first stop **on D**, not within the trailing month. A driver first stopping
five days ago is retained since both overlapping windows include that stop. A return
on D following a stop on D-30 is retained; a return after the last stop before D-30 is
resurrected. Churned is a one-day expiry; without a return the driver is stale next day.

No inactive driver-days are stored. Daily snapshots are non-additive. Use aligned
first-stop/activity history and sufficient prehistory; inherited watermark and source
retraction limitations still apply. See [ADR 0012](../../docs/adr/0012-mad-lifecycle-partition.md)
for window arithmetic and ADR 0014 for the revised event-time basis.

### Selected-period driver cohorts for Chat BI investigations

For questions such as "did new drivers explain the visit-success dip in the last two
hours?", use the [Chat BI skill](../../demo/chat-bi/skills/driver-period-cohorts/SKILL.md)
and [DuckDB sample SQL](../../demo/chat-bi/skills/driver-period-cohorts/references/period_driver_cohorts.sql).
This is query-time analysis, not a new published metric or a static semantic dimension
that automatically receives a query-selected reporting start.

For [S, E), identified drivers are active with at least one attempt stop in that window:

| Selected-period cohort | Definition |
| --- | --- |
| New | First-ever observed attempt stop in [S, E) |
| Retained | First stop before S, with a stop in [S minus 30 days, S) |
| Resurrected | First stop before S, with no stop in that preceding window |

A first attempt starting before S and stopping inside is New. Freeze one membership per
credential for the whole period, including repeated attempts/visits. With complete,
aligned history, active = new + retained + resurrected. Churned/stale are inactive;
unknown credentials are excluded from driver counts and shown separately for visits.

Use timestamped attempts and migrated stop-based `dim_drivers.first_seen_ts`. Daily
activity cannot resolve intraday boundaries; current last seen cannot reconstruct
pre-period history. Keep history network-wide when current traffic is location-filtered.
Flag inconsistent history and confirm the coordinated stop-time rebuild, rather than
mixing old start-based dimension values with stop-based queries. The 14-day seed alone
cannot establish complete 30-day or lifetime history.

Selected-period New means first stop anywhere in [S, E), while daily MAD New means first
stop on D. Selected-period retained/resurrected use the pre-S lookback; daily metrics
retain their existing overlapping-window formulas. Both now use stop-based activity.

Processing has a **35-minute SLA**. If met, the expected processed cutoff is captured
clock minus 35 minutes. Literal last two hours remains [clock minus 120 minutes, clock),
with recent results provisional. Latest fully processed two hours means
[clock minus 155 minutes, clock minus 35 minutes). Never silently shift requested bounds.
The SLA addresses processing lag, not visit finalization.

For visit analysis, join the one-row-per-driver cohort without fanout and preserve
mart success definitions. Visits use visit_end_ts, not attempt-stop attribution. Keep
unmatched identified visits visible separately from unidentified visits. Do not treat
ongoing visits as failed; non-null end/stop timestamps do not prove buffered visits are
finalized. Use visit shares and matched historical cohort success rates to explain mix,
not driver shares or causal claims. See the skill and
[ADR 0013](../../docs/adr/0013-query-time-driver-period-cohorts.md).


## Grouping and join guidance

- Use `metric_time` for each metric's default time basis; it maps to the column listed above.
  Driver activity/acquisitions use stops; attempt-level measures retain start attribution,
  and visit metrics retain visit-end attribution. These populations need not match.

- Use `location__location_id` for metrics with the conformed location entity. Visits use the
  visit location; attempts, uptime, and downtime use their stored/resolved location keys.
- A visit's `port` entity and `charge_attempt` entity refer to its **last** Port and attempt,
  not every Port or attempt involved in the visit. First/last Charger dimensions are explicit.
- Ports and Connectors carry `charger_id`. Their current location is reached
  through the Charger entity.

- Hardware dimensions describe current state. `connector__latest_status` is not historical
  status at an outage or visit timestamp, and Charger location changes are not SCD history.
- ChargeX attributes apply to ChargeX-coded errors only. Null flags after a left join do not
  mean false or that a non-ChargeX error belongs to a particular category. Error taxonomy
  identifies the code scheme, not the Charger manufacturer.
- Connector metadata is exposed for current operational context; there is no historical
  Connector foreign entity on the attempt, visit, or activity semantic models.