{% macro json_array_unnest(json_column, alias) %}
    {#
      Cross-warehouse compatible unnest for JSON arrays
      
      Args:
        json_column: The JSON array column to unnest
        alias: The alias for the unnest result (e.g., 'mv')
      
      Example:
        cross join {{ json_array_unnest('meter_values', 'mv') }}
    #}
    {% if target.type == 'snowflake' %}
        cross join lateral flatten(input => parse_json({{ json_column }})) as {{ alias }}
    {% elif target.type == 'bigquery' %}
        cross join unnest(json_extract_array({{ json_column }})) as {{ alias }}
    {% elif target.type == 'duckdb' %}
        cross join unnest(json_extract({{ json_column }}, '$')) as {{ alias }}
    {% elif target.type in ['postgres', 'redshift'] %}
        cross join unnest({{ json_column }}) as {{ alias }}
    {% elif target.type in ['spark', 'databricks'] %}
        cross join lateral explode({{ json_column }}) as {{ alias }}
    {% elif target.type in ['trino', 'presto', 'athena'] %}
        cross join unnest(json_extract_array({{ json_column }}, '$')) as {{ alias }}
    {% else %}
        -- Fallback for other warehouses - may need adjustment
        cross join unnest({{ json_column }}) as {{ alias }}
    {% endif %}
{% endmacro %}
