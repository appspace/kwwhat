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
    cross join lateral flatten(input => parse_json({{ json_column }}))
{% endmacro %}

{% macro bigquery__json_array_unnest(json_column) %}
    cross join unnest(json_extract_array({{ json_column }}))
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
