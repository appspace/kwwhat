# Kimball Compliance Audit

## Blocking issues

### All five fact tables — natural keys used as FK references

`fact_charge_attempts`, `fact_downtime_daily`, `fact_interval_data`, `fact_uptime`, and `fact_visits` all reference `charge_point_id`, `port_id`, `connector_id`, `location_id` as raw natural keys. Kimball requires facts to reference surrogate keys from dim tables. There are no `port_key` or `location_key` FK columns anywhere.

### `dim_ports` — no surrogate key

The model has no generated surrogate key. It uses the natural composite key (`charge_point_id + port_id + connector_id`) directly. A `port_key` column generated with `dbt_utils.generate_surrogate_key` is missing, and the natural key is not preserved as `port_natural_key`.

### `dim_ports` — no SCD type declared

`commissioned_ts` and `decommissioned_ts` are mutable attributes (a port can be decommissioned). The SCD type is not declared anywhere in the description or column docs.

---

## Grain not explicitly stated

| Model | What the description says | What it should say |
|-------|--------------------------|-------------------|
| `dim_ports` | "Port/connector dimension" | "One row per charge_point_id + port_id + connector_id" |
| `fact_charge_attempts` | "combines charge attempts and transactions data" | "One row per charge attempt per port" |
| `fact_downtime_daily` | "Daily aggregation of charge point downtime" | "One row per date + charge_point_id + port_id + outage type" |
| `fact_interval_data` | "15-minute interval meter values" | "One row per charge_point_id + transaction_id + connector_id + ingested_ts + measurand + unit + phase + 15-min interval" |

`fact_uptime` is the only model that states its grain correctly: "One row per charge point, port, and day."

---

## Non-additive measures not documented

**`fact_uptime.uptime`** — this is a ratio (fraction between 0 and 1). Ratios are non-additive: summing uptime across ports produces a meaningless number. Not documented.

**`fact_interval_data.avg_value`** — averages cannot be re-aggregated by SUM. Not documented as non-additive.

---

## Descriptive attributes in fact tables

**`fact_charge_attempts`** — `previous_status`, `status`, `next_status`, `transaction_stop_reason`, `id_tags`, `id_tag_statuses`, `error_codes` are all descriptive. None are documented as degenerate dimensions.

**`fact_downtime_daily`** — `type` (OFFLINE/FAULTED) is a low-cardinality categorical attribute. It could be a degenerate dimension or should be explained as such.

**`fact_visits`** — `grouping_key` is an internal implementation column with no business meaning. It should not appear in a mart output. `charge_attempt_ids` and `charge_point_ids` are arrays — arrays in mart tables are non-standard in dimensional modeling and create downstream join difficulties.

---

## `dim_dates` — no primary key test

`date_day` / `date_id` has no `not_null` or `unique` data test. The `granularity: day` metadata is MetricFlow config, not a data quality test. Using the date itself as the key is a common pragmatic exception to surrogate keys, but the absence of any uniqueness test is a gap.

---

## `fact_downtime_daily` — nullable column in the grain

`port_id` is documented as "may be null if unavailable" but is part of the unique key (`date_id + charge_point_id + port_id + type`). The `downtime_id` surrogate key is generated from this nullable column — multiple rows with `port_id = null` on the same date and type would produce identical surrogate keys.

---

## Summary by model

| Model | Blocking | Other issues |
|-------|---------|-------------|
| `dim_ports` | No surrogate key, no SCD type | Grain implicit, no `port_natural_key` |
| `dim_dates` | — | No PK test |
| `fact_charge_attempts` | Natural key FKs | Descriptive attrs, grain implicit |
| `fact_downtime_daily` | Natural key FKs | Nullable grain column, `type` undocumented degenerate dim |
| `fact_interval_data` | Natural key FKs | Non-additive avg_value undocumented, grain implicit |
| `fact_uptime` | Natural key FKs | Non-additive ratio undocumented |
| `fact_visits` | Natural key FKs | `grouping_key` leaking, arrays in mart, grain implicit |
