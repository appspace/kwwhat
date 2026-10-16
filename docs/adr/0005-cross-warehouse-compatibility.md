# 0005. Cross-warehouse compatibility through dispatched kwwhat macros

- Status: Accepted
- Date: 2026-10-15 (backfilled; decision predates this record)
- Related: #168, `macros/`

## Context

The project must run unchanged on Snowflake and BigQuery, with Postgres and DuckDB also
supported (#168). Arrays, JSON, date math and type coercion differ by adapter, and Snowflake
tolerates code that BigQuery rejects.

## Decision

- Adapter-specific SQL lives in macros using `adapter.dispatch`, never
  `{% if target.type == ... %}` branches in models.
- Use `dbt.` built-ins where they behave the same everywhere; otherwise add a `kwwhat`-namespaced
  macro (`array_agg_distinct`, `json_array_unnest`, `timestamp_add`, ...).
- Do not override dbt's own adapter macros. Example: on BigQuery `dbt.dateadd` returns DATETIME,
  which fails against TIMESTAMP columns. Rather than overriding `bigquery__dateadd`, models call
  `kwwhat.timestamp_add`, so `dbt_utils.date_spine` and other package macros keep their
  documented behavior.

## Alternatives considered

- **`target.type` branches in models.** Spreads adapter logic across every model and cannot be
  overridden by downstream projects.
- **Override dbt's built-in adapter macros.** Fixes our models but silently changes behavior of
  dbt and package macros that depend on them.

## Consequences

- Each adapter implementation can be read and tested on its own.
- Contributors must use project macros instead of familiar functions; the rules are in
  `CLAUDE.md`.
- Passing on Snowflake is not proof of correctness; changes need testing on BigQuery too.
