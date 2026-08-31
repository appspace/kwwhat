{#
  Overrides dbt-core's global bigquery__dateadd (dbt.dateadd() dispatches here on BigQuery).

  dbt-bigquery's dateadd() casts its input to datetime and returns datetime_add(...) - a
  DATETIME - regardless of the input's own type. Every other temporal helper in this project
  (dbt.date_trunc(), the explicit casts to dbt.type_timestamp() in staging) produces
  TIMESTAMP, and BigQuery has no implicit cast between DATETIME and TIMESTAMP, so mixing a
  raw dateadd() result with a timestamp column in a comparison, LEAST/GREATEST, or date math
  fails with "No matching signature" errors. This keeps the DATETIME_ADD call (needed since
  BigQuery's TIMESTAMP_ADD doesn't support week/month/quarter/year intervals) but casts the
  result back to the project's canonical TIMESTAMP type, matching dateadd()'s behavior on
  every other adapter (Snowflake, Postgres, Redshift, etc. all preserve/return a
  timestamp-family type here already). This also fixes dbt_utils.date_spine() - it builds its
  date column via dbt.dateadd() internally, so dim_dates.date_id gets a consistent TIMESTAMP
  type on BigQuery too, with no changes needed to dim_dates.sql itself.
#}
{% macro bigquery__dateadd(datepart, interval, from_date_or_timestamp) %}
    cast(
        datetime_add(
            cast({{ from_date_or_timestamp }} as datetime),
            interval {{ interval }} {{ datepart }}
        )
        as {{ dbt.type_timestamp() }}
    )
{% endmacro %}
