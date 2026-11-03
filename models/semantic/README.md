# Semantic models

This folder holds the dbt **semantic layer** definitions used for metrics and BI.

## Contents

- **`semantic_models.yml`** — dbt semantic models and metrics:
  - **visits** — Visit-level semantic model (backed by `fact_visits`): dimensions, measures, and metrics for charging visits, success/failure, first-attempt vs troubled success.
  - **charge_attempts** — Charge-attempt-level semantic model (backed by `fact_charge_attempts`): dimensions and measures for individual charge attempts and success rates.
  - **uptime** — Port-level daily uptime (backed by `fact_uptime_daily`): dimensions charger_id, port_id, date_id; measures commissioned_minutes_total, uptime_minutes_total, downtime_minutes_total, offline_downtime_minutes_total and faulted_downtime_minutes_total.

- **Snowflake semantic view** — Spec lives in `snowflake/semantic_view.yml` (outside `models/` so dbt does not parse it). Snowflake’s native schema-level format for Cortex Analyst; YAML is consumed by Snowflake to create a semantic view in your database. See the [Snowflake semantic view YAML specification](https://docs.snowflake.com/en/user-guide/views-semantic/semantic-view-yaml-spec).

## Upstream models

Semantic models reference marts only. 
- Visits are charging visits: one row per stop at a charge location, from first attempt to when the user is done; a visit can include multiple charge attempts. 
- Charge attempts are individual attempts to charge; a visit aggregates one or more charge attempts.

## Metrics

| Metric name | Definition |
| ---------- | ---------- |
| total_visits | Total number of charging visits |
| total_successful_visits | Total number of charging visits where the driver successfully charged |
| total_charge_attempts | Total number of charge attempts across all visits |
| average_attempts_per_visit | Average number of charge attempts per visit (total charge attempts / total visits) |
| first_attempt_success | Count of successful visits with just one attempt |
| troubled_success | Count of visits that succeeded after multiple attempts |
| failed_visits | Count of visits that failed |
| first_attempt_success_rate | Share of first attempt success |
| troubled_success_rate | Share of troubled success |
| failed_rate | Share of failed visits |
| uptime_ratio | Duration-weighted port uptime: total uptime minutes / total commissioned minutes |
| total_commissioned_minutes | Total minutes ports were commissioned |
| total_uptime_minutes | Total commissioned minutes ports were up, not in outage |
| total_downtime_minutes | Total minutes ports were down (OFFLINE + FAULTED), by port, charger, location and date |
| total_downtime_minutes_detailed | Same total, sliceable by downtime_type, reason and error code; use it to find out why ports were down |

## Usage

Steep — [Steep](https://steep.app/) is a modern analytics platform powered by metrics. Connect the dbt Semantic Layer so metrics defined here are available in Steep. See [Steep: dbt Cloud integration](https://help.steep.app/integrations/dbt-cloud).

<img width="1376" height="658" alt="steep" src="https://github.com/user-attachments/assets/d1870b3a-06c3-4f49-9c59-921420413cda" />


Google Sheets — Use the dbt Semantic Layer add-on for Google Sheets to query metrics and dimensions from a sheet. See [dbt Semantic Layer: Google Sheets](https://docs.getdbt.com/docs/cloud-integrations/semantic-layer/gsheets).

<img width="1004" height="620" alt="google sheets" src="https://github.com/user-attachments/assets/4bb65624-09d8-46c9-97d0-6a1f14cc1578" />



Snowflake — The Snowflake semantic view (`snowflake/README.md`) is for Cortex Analyst and is created in Snowflake from that YAML spec; it is separate from the dbt Semantic Layer. See [Snowflake semantic views overview](https://docs.snowflake.com/en/user-guide/views-semantic/overview) and the [YAML specification](https://docs.snowflake.com/en/user-guide/views-semantic/semantic-view-yaml-spec).

<img width="1296" height="760" alt="snowflake intelligence" src="https://github.com/user-attachments/assets/b9735ef5-524c-442a-98c4-d68528c57732" />



MCP server and in-house text-to-SQL — Enable the [dbt MCP server](https://docs.getdbt.com/docs/dbt-ai/about-mcp) to expose dbt models, metrics, and lineage to MCP clients (e.g. Cursor, Claude Desktop). Use it to implement in-house text-to-SQL or agents that query the Semantic Layer with governed metric definitions instead of raw tables. Check these [5 steps to deploy an analytics agent on dbt MCP to your whole company](https://thenewaiorder.substack.com/p/5-steps-to-deploy-an-analytics-agent) to learn from the founder of [nao](https://github.com/getnao/nao), an open-source project for deploying AI agents on file system context plus any MCP.


## Driver activity and growth accounting

`driver_activity` reads the sparse `fact_driver_activity_daily` table. An identified driver
is active when they make any charge attempt, including unsuccessful attempts. The unit is
an observed driver credential (id_tag), not a resolved person. Unknown activity is excluded.

| Metric | Meaning on as-of date D |
| ------ | ---------------------- |
| active_drivers_7d | Distinct drivers active on D-6 through D |
| active_drivers_30d | Distinct drivers active on D-29 through D; fixed 30 days, not a calendar month |
| new_drivers | Drivers whose first observed activity was on D, shared by both window sizes |
| retained_drivers_7d / retained_drivers_30d | Drivers in both today's and yesterday's corresponding rolling active sets |
| resurrected_drivers_7d / resurrected_drivers_30d | Drivers entering today's rolling set after being absent from yesterday's set, excluding first-ever drivers |
| churned_drivers_7d / churned_drivers_30d | Drivers in yesterday's rolling set who have aged out of today's set |

Retained does not require charging again on D. Churned describes window expiry, not permanent
customer loss. The 8-day and 31-day `driver_activity_union_*` helper metrics provide the union
needed for exact set arithmetic without another stored state table.

Query growth accounting with `metric_time__day` and an explicit date range. Use completed,
fully ingested dates only, with enough prehistory for the 8-day or 31-day union. Metric values
are not automatically capped to source completeness. At initial history boundaries, prior
activity is unknown, so treat those dates as warm-up. Filter metric_time rather than activity
date to preserve the lookback. Do not sum daily active or retained counts. Coarser active
queries return the last daily snapshot; coarser growth-accounting queries are not supported
by these definitions.

The daily identities are active = new + retained + resurrected, and change in active = new +
resurrected - churned. First-seen data comes from `dim_drivers`; a data test checks its alignment
with sparse activity. Definitions and limitations are in
[ADR 0011](../../docs/adr/0011-overlapping-driver-growth-accounting.md).


Validation includes `assert_driver_activity_first_seen_consistent` for warehouse history
alignment and `assert_overlapping_driver_growth_formulas` for synthetic driver-set boundary
cases against the configured derived expressions. The latter checks formula arithmetic,
not the full MetricFlow query planner; warehouse semantic validation and query checks are
also required.

Consume these metrics through the dbt Semantic Layer. The OSI export currently warns that
it cannot represent cumulative window semantics; exporting these definitions does not
preserve the rolling-count contract.
