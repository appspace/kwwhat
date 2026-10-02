{% macro timestamp_add(datepart, interval, from_date_or_timestamp) %}
    {#
      Adds an interval and always returns a TIMESTAMP, the project's canonical time type.
      Use this in models instead of dbt.dateadd().
      Example: {{ timestamp_add('minute', 15, 'interval_start') }}

      On most adapters this is just dbt.dateadd(). On BigQuery, dbt.dateadd() returns a
      DATETIME, and BigQuery has no implicit cast between DATETIME and TIMESTAMP, so
      comparing its result with a timestamp column (or using it in least/greatest) fails
      with "No matching signature". This lives in the kwwhat namespace instead of
      overriding dbt's own bigquery__dateadd, so dbt and package macros that call
      dbt.dateadd() internally (e.g. dbt_utils.date_spine) keep their documented behavior.
    #}
    {{ return(adapter.dispatch('timestamp_add', 'kwwhat')(datepart, interval, from_date_or_timestamp)) }}
{% endmacro %}

{% macro default__timestamp_add(datepart, interval, from_date_or_timestamp) %}
    {{ dbt.dateadd(datepart, interval, from_date_or_timestamp) }}
{% endmacro %}

{% macro bigquery__timestamp_add(datepart, interval, from_date_or_timestamp) %}
    {#
      datetime_add rather than timestamp_add: BigQuery's timestamp_add only supports
      intervals up to day, and the incremental_window var uses months.
    #}
    cast(
        datetime_add(
            cast({{ from_date_or_timestamp }} as datetime),
            interval {{ interval }} {{ datepart }}
        )
        as {{ dbt.type_timestamp() }}
    )
{% endmacro %}
