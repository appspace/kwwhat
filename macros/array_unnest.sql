{% macro array_unnest(array_column) %}
    {#
      Cross-warehouse compatible unnest for native (non-JSON) arrays. For json-encoded
      array columns, use json_array_unnest instead.
      Example: cross join {{ array_unnest('error_codes') }} as ec - reference the element
      via ec.value (Snowflake's flatten output column; other adapters bind the alias itself).
    #}
    {{ return(adapter.dispatch('array_unnest', 'kwwhat')(array_column)) }}
{% endmacro %}

{% macro default__array_unnest(array_column) %}
    cross join unnest({{ array_column }})
{% endmacro %}

{% macro snowflake__array_unnest(array_column) %}
    cross join lateral flatten(input => {{ array_column }})
{% endmacro %}

{% macro bigquery__array_unnest(array_column) %}
    cross join unnest({{ array_column }})
{% endmacro %}
