{% macro json_array_unnest(json_column) %}
    {#
      Cross-warehouse compatible unnest for JSON arrays.
      Example: cross join {{ json_array_unnest('meter_values') }}
    #}
    {{ return(adapter.dispatch('json_array_unnest', 'kwwhat')(json_column)) }}
{% endmacro %}

{% macro default__json_array_unnest(json_column) %}
    cross join unnest({{ json_column }})
{% endmacro %}

{% macro snowflake__json_array_unnest(json_column) %}
    {#
      No parse_json() here: callers only ever pass a value already produced by
      json_extract_array()/meter_values_json (kwwhat macros), which on Snowflake is
      already a variant - re-parsing it would just round-trip it through text for no
      reason.
    #}
    cross join lateral flatten(input => {{ json_column }})
{% endmacro %}

{% macro bigquery__json_array_unnest(json_column) %}
    {#
      No json_extract_array() here: callers only ever pass a value already produced by
      json_extract_array()/meter_values_json (kwwhat macros), which on BigQuery is already
      an ARRAY - re-extracting it fails ("Unable to coerce type ARRAY<STRING> to expected
      type STRING"). Wrapped in a one-field struct so callers can use `<alias>.value`
      uniformly across adapters - Snowflake's flatten() already exposes elements that way,
      but a bare `unnest(array<string>) as mv` makes `mv` the scalar itself, with no `.value`
      to access ("Cannot access field value on a value with type STRING").
    #}
    cross join unnest(array(select as struct x as value from unnest({{ json_column }}) as x))
{% endmacro %}

{% macro duckdb__json_array_unnest(json_column) %}
    cross join (select unnest(json_transform({{ json_column }}, '["JSON"]')) as value)
{% endmacro %}

{% macro postgres__json_array_unnest(json_column) %}
    cross join unnest({{ json_column }})
{% endmacro %}

{% macro redshift__json_array_unnest(json_column) %}
    cross join unnest({{ json_column }})
{% endmacro %}

{% macro spark__json_array_unnest(json_column) %}
    cross join lateral explode({{ json_column }})
{% endmacro %}

{% macro databricks__json_array_unnest(json_column) %}
    cross join lateral explode({{ json_column }})
{% endmacro %}

{% macro trino__json_array_unnest(json_column) %}
    cross join unnest(json_extract_array({{ json_column }}, '$'))
{% endmacro %}

{% macro presto__json_array_unnest(json_column) %}
    cross join unnest(json_extract_array({{ json_column }}, '$'))
{% endmacro %}

{% macro athena__json_array_unnest(json_column) %}
    cross join unnest(json_extract_array({{ json_column }}, '$'))
{% endmacro %}
