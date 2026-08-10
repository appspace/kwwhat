{% macro date_spine_literal(date_string) %}
    {#
      Cross-warehouse-safe start_date/end_date literal for dbt_utils.date_spine().
      Example: {{ dbt_utils.date_spine(datepart="day", start_date=date_spine_literal('2020-01-01'), end_date=date_spine_literal('2050-12-31')) }}
    #}
    {{ return(adapter.dispatch('date_spine_literal', 'kwwhat')(date_string)) }}
{% endmacro %}

{% macro default__date_spine_literal(date_string) %}
    cast('{{ date_string }}' as date)
{% endmacro %}

{% macro bigquery__date_spine_literal(date_string) %}
    {#
      date_spine() builds its date column via dbt.dateadd(), which this project's
      bigquery__dateadd() override (see macros/bigquery_dateadd.sql) always returns as
      TIMESTAMP. date_spine()'s own end_date filter (`date_col <= end_date`) then needs
      end_date to be TIMESTAMP too - BigQuery has no implicit cast from a DATE literal to
      TIMESTAMP (only to DATETIME), so a plain `cast(... as date)` here fails that
      comparison with "No matching signature for operator <=".
    #}
    cast('{{ date_string }}' as {{ dbt.type_timestamp() }})
{% endmacro %}
