# Semantic models and metrics

Use the dbt Semantic Layer for governed charging reliability, driver visit outcomes, and
historical driver activity. Definitions live in `semantic_models.yml` and reference marts
only. The file uses the supported legacy YAML format with separate semantic models,
measures, and metrics. A measure is a building block; only a declared metric is directly
queryable as a metric.

Start with [the project definitions](../../README.md#definitions) for the Charger, Port,
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
historical/current-state attributions. See [ADR 0009](../../docs/adr/0009-duration-weighted-uptime.md).

## Driver activity and growth accounting

An identified driver is active when they make any charge attempt, including unsuccessful
attempts. The unit is an observed credential (`id_tag`), not a resolved human identity.
Null and reserved UNKNOWN identifiers are excluded from activity and acquisition metrics.

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

See [ADR 0010](../../docs/adr/0010-sparse-driver-day-activity.md) and
[ADR 0011](../../docs/adr/0011-overlapping-driver-growth-accounting.md).

## Grouping and join guidance

- Use `metric_time` for each metric's default time basis; it maps to the column listed above.
  Combining visits and activity on a date compares visit endings with attempt-start activity.
- Use `location__location_id` for metrics with the conformed location entity. Visits use the
  visit location; attempts, uptime, and downtime use their stored/resolved location keys.
- A visit's `port` entity and `charge_attempt` entity refer to its **last** Port and attempt,
  not every Port or attempt involved in the visit. First/last Charger dimensions are explicit.
- Ports and Connectors carry `charger_id`, not `location_id`. Their current location is reached
  through the Charger entity. Removed `port__location_id` and `connector__location_id`
  definitions referenced nonexistent columns. For visit metrics, use
  `port__charger__location_id` for the last Port's current Charger location, or
  `location__location_id` for the visit's stored location attribution.

- Hardware dimensions describe current state. `connector__latest_status` is not historical
  status at an outage or visit timestamp, and Charger location changes are not SCD history.
- ChargeX attributes apply to ChargeX-coded errors only. Null flags after a left join do not
  mean false or that a non-ChargeX error belongs to a particular category. Error taxonomy
  identifies the code scheme, not the Charger manufacturer.
- Connector metadata is exposed for current operational context; there is no historical
  Connector foreign entity on the attempt, visit, or activity semantic models.

## Validation and publishing

Run `dbt parse`, followed by `dbt sl validate` against the intended warehouse environment.
Validation checks semantic SQL and referenced columns; it does not prove ingestion completeness.
The regression tests check first-seen/activity alignment, configured growth expressions against
synthetic driver sets, and agreement between the attempt success dimension and the mart flag.
Formula tests complement MetricFlow planner and runtime checks.

Consume rolling metrics through the dbt Semantic Layer. The OSI export currently warns that
it cannot represent cumulative window semantics, so it is not an equivalent rolling-metric
contract. Snowflake native semantic views use a separate specification and deployment;
this checkout does not include `snowflake/semantic_view.yml` or `snowflake/README.md`.

## Integrations

**Steep:** Connect the dbt Semantic Layer to query these metrics in
[Steep](https://steep.app/). See the [dbt integration guide](https://help.steep.app/integrations/dbt-cloud).

<img width="1376" height="658" alt="Steep metric exploration" src="https://github.com/user-attachments/assets/d1870b3a-06c3-4f49-9c59-921420413cda" />

**Google Sheets:** Use the [dbt Semantic Layer add-on](https://docs.getdbt.com/docs/cloud-integrations/semantic-layer/gsheets)
to query governed metrics and dimensions from a spreadsheet.

<img width="1004" height="620" alt="Google Sheets Semantic Layer integration" src="https://github.com/user-attachments/assets/4bb65624-09d8-46c9-97d0-6a1f14cc1578" />

**Snowflake Cortex Analyst:** A separately deployed Snowflake semantic view can provide native
context. It is not created by this dbt semantic YAML and metric parity should not be assumed.
See the [Snowflake semantic views overview](https://docs.snowflake.com/en/user-guide/views-semantic/overview).

<img width="1296" height="760" alt="Snowflake Intelligence example" src="https://github.com/user-attachments/assets/b9735ef5-524c-442a-98c4-d68528c57732" />

**MCP and in-house agents:** The [dbt MCP server](https://docs.getdbt.com/docs/dbt-ai/about-mcp)
exposes dbt models, metrics, and lineage to compatible clients. Prefer governed metrics for
analytical answers; operational SQL access is not a substitute for a declared metric.
