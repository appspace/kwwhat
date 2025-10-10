{% macro array_contains(array_column, value) %}
    {#
      Platform-invariant array contains function:
      - Checks if a value exists in an array column
      - Handles different SQL dialects for array operations
      Example: {{ array_contains('my_array_col', 'search_value') }}
    #}
    {% if target.type == "snowflake" %}
        array_contains({{ value }}::variant,{{ array_column }})
    {% elif target.type in ["postgres", "redshift"] %}
        {{ value }} = any({{ array_column }})
    {% elif target.type == "bigquery" %}
        {{ value }} in unnest({{ array_column }})
    {% elif target.type in ["spark", "databricks"] %}
        array_contains({{ array_column }}, {{ value }})
    {% elif target.type in ["trino", "presto", "athena"] %}
        contains({{ array_column }}, {{ value }})
    {% elif target.type == "duckdb" %}
        list_contains({{ array_column }}, {{ value }})
    {% else %} 
        {{ value }} = any({{ array_column }})
    {% endif %}
{% endmacro %}
