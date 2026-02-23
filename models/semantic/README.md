# Semantic models

This folder holds the dbt **semantic layer** definitions used for metrics and BI.

## Contents

- **`semantic_models.yml`** — dbt semantic models and metrics:
  - **visits** — Visit-level semantic model (backed by `fact_visits`): dimensions, measures, and metrics for charging visits, success/failure, first-attempt vs troubled success.
  - **charge_attempts** — Charge-attempt-level semantic model (backed by `fact_charge_attempts`): dimensions and measures for individual charge attempts and success rates.

- **Snowflake semantic view** — Spec lives in `snowflake/semantic_view.yml` (outside `models/` so dbt does not parse it). Snowflake’s native schema-level format for Cortex Analyst; YAML is consumed by Snowflake to create a semantic view in your database. See the [Snowflake semantic view YAML specification](https://docs.snowflake.com/en/user-guide/views-semantic/semantic-view-yaml-spec).

## Upstream models

Semantic models reference marts only. 
- Visits are charging visits: one row per stop at a charge location, from first attempt to when the user is done; a visit can include multiple charge attempts. 
- Charge attempts are individual attempts to charge; a visit aggregates one or more charge attempts.

## Metrics

| Metric name | Definition |
| ---------- | ---------- |
| total_visits | Total number of charging visits |
| total_charge_attempts | Total number of charge attempts across all visits |
| average_attempts_per_visit | Average number of charge attempts per visit (total charge attempts / total visits) |
| first_attempt_success | Count of successful visits with just one attempt |
| troubled_success | Count of visits that succeeded after multiple attempts |
| failed_visits | Count of visits that failed |
| first_attempt_success_rate | Share of first attempt success |
| troubled_success_rate | Share of troubled success |
| failed_rate | Share of failed visits |

## Usage

Steep — [Steep](https://steep.app/) is a modern analytics platform powered by metrics. Connect the dbt Semantic Layer so metrics defined here are available in Steep. See [Steep: dbt Cloud integration](https://help.steep.app/integrations/dbt-cloud).

<img width="1376" height="658" alt="steep" src="https://github.com/user-attachments/assets/d1870b3a-06c3-4f49-9c59-921420413cda" />


Google Sheets — Use the dbt Semantic Layer add-on for Google Sheets to query metrics and dimensions from a sheet. See [dbt Semantic Layer: Google Sheets](https://docs.getdbt.com/docs/cloud-integrations/semantic-layer/gsheets).

<img width="1004" height="620" alt="google sheets" src="https://github.com/user-attachments/assets/4bb65624-09d8-46c9-97d0-6a1f14cc1578" />



Snowflake — The Snowflake semantic view (`snowflake/README.md`) is for Cortex Analyst and is created in Snowflake from that YAML spec; it is separate from the dbt Semantic Layer. See [Snowflake semantic views overview](https://docs.snowflake.com/en/user-guide/views-semantic/overview) and the [YAML specification](https://docs.snowflake.com/en/user-guide/views-semantic/semantic-view-yaml-spec).

<img width="1296" height="760" alt="snowflake intelligence" src="https://github.com/user-attachments/assets/b9735ef5-524c-442a-98c4-d68528c57732" />



MCP server and in-house text-to-SQL — Enable the [dbt MCP server](https://docs.getdbt.com/docs/dbt-ai/about-mcp) to expose dbt models, metrics, and lineage to MCP clients (e.g. Cursor, Claude Desktop). Use it to implement in-house text-to-SQL or agents that query the Semantic Layer with governed metric definitions instead of raw tables.
