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

An identified driver is active when they make any charge attempt, including unsuccessful
attempts. The unit is an observed credential (`id_tag`), not a resolved human identity.
Activity and acquisition metrics exclude unauthenticated drivers.

| Metric | Meaning on as-of date D |
| --- | --- |
| `active_drivers_7d` | Distinct drivers active on D-6 through D inclusive |
| `active_drivers_30d` | Distinct drivers active on D-29 through D; fixed 30 days, not a calendar month |
| `new_drivers` | Drivers first observed on D, shared by both window sizes |
| `retained_drivers_7d` / `retained_drivers_30d` | Drivers in both today's and yesterday's corresponding rolling active sets |
| `resurrected_drivers_7d` / `resurrected_drivers_30d` | Drivers entering today's rolling set after absence from yesterday's set, excluding first-ever drivers |
| `churned_drivers_7d` / `churned_drivers_30d` | Drivers in yesterday's rolling set who have aged out of today's set |

Retained does not require charging again on D. Churned describes window expiry, not permanent
customer loss. `new_drivers` counts acquisitions on D, not all acquisitions within a trailing
window. First-ever means first observed in the project's available history.

The `driver_activity_union_8d` and `driver_activity_union_31d` helper metrics count the union
of today's and yesterday's active sets. They support exact set arithmetic without another
stored state table and are not headline engagement metrics. The daily identities are:

- active = new + retained + resurrected
- change in active = new + resurrected - churned

Query growth accounting with `metric_time__day` and an explicit date range. Use completed,
fully ingested dates with enough prehistory for the 8-day or 31-day union; initial history
boundaries are warm-up. Metric values are not automatically capped to source completeness.
Filter metric time instead of activity date to preserve the lookback. Do not sum daily
active or retained counts. Coarser active queries select the last daily snapshot; these
definitions do not support coarser growth-accounting queries.

`drivers` uses first-seen time for acquisitions; its last-seen attribute cannot reconstruct
historical active sets. Current authorization attributes are Type 1 and do not represent
historical authorization state. Network activity has no location/Port grain, so local
new-driver and local-retention metrics are not defined.

### MAD lifecycle stack

`mad` means monthly active drivers over a **fixed trailing 30 days**, not a calendar
month. For each reporting day D, compare D-29..D with D-30..D-1:

| Metric | Daily classification |
| --- | --- |
| `mad_new` | First observed on D |
| `mad_retained` | Active in both windows, whether or not they charged on D |
| `mad_resurrected` | Active in the current window only, first observed before D |
| `mad_churned` | Active in the previous window only; last activity on D-30 |
| `mad_stale` | Observed by D, active in neither window; last activity before D-30 |

The five categories are mutually exclusive and exhaustive over **identified drivers first
observed by D**. Drivers first observed after D are excluded from that day's population.
`drivers_observed_to_date` is an all-time cumulative acquisition helper, not today's total
number of rows in `dim_drivers`.

- `mad = mad_new + mad_retained + mad_resurrected`
- `drivers_observed_to_date = mad_new + mad_retained + mad_resurrected + mad_churned + mad_stale`
- `mad_stale = drivers_observed_to_date - driver_activity_union_31d`

For a daily stacked lifecycle chart, use the five categories as positive series, with
New, retained, and resurrected together as the active portion. Churned and stale are
inactive; the complete stack represents all drivers observed by D, not MAD alone.
Use just the three active categories for a stack whose height is MAD. Do not add `mad`
as a sixth lifecycle series because that double-counts the active categories.

New is first observed **on D**, not during the last 30 days. A driver first seen five days
ago is retained because the two overlapping windows both contain that first attempt.
A return on D after activity on D-30 is also retained; a return after last activity before
D-30 is resurrected. Churned is a one-day window-expiry transition; without a return,
that driver is stale the following day.

These metrics reuse the existing 30-day accounting definitions and store no inactive
driver-days. Query `metric_time__day`, preserve the lookback by filtering metric time,
and use completed, fully ingested dates with aligned first-seen/activity history and
sufficient prehistory. Five-way accounting is not defined at coarser time grains, and
stale/retained/active daily snapshots must not be summed over dates. Source history and
watermark limitations remain those documented above and in ADRs 0010 and 0011.
See [ADR 0012](../../docs/adr/0012-mad-lifecycle-partition.md).


## Grouping and join guidance

- Use `metric_time` for each metric's default time basis; it maps to the column listed above.
  Combining visits and activity on a date compares visit endings with attempt-start activity.
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