{% macro json_array_unnest(json_column) %}
    {#
      Cross-warehouse compatible unnest for JSON arrays
      
      Args:
        json_column: The JSON array column to unnest
      
      Example:
        cross join {{ json_array_unnest('meter_values') }}
    #}
    {% if target.type == 'snowflake' %}
        cross join lateral flatten(input => parse_json({{ json_column }}))
    {% elif target.type == 'bigquery' %}
        cross join unnest(json_extract_array({{ json_column }}))
    {% elif target.type == 'duckdb' %}
        cross join unnest(json_extract({{ json_column }}, '$'))
    {% elif target.type in ['postgres', 'redshift'] %}
        cross join unnest({{ json_column }})
    {% elif target.type in ['spark', 'databricks'] %}
        cross join lateral explode({{ json_column }})
    {% elif target.type in ['trino', 'presto', 'athena'] %}
        cross join unnest(json_extract_array({{ json_column }}, '$'))
    {% else %}
        -- Fallback for other warehouses - may need adjustment
        cross join unnest({{ json_column }})
    {% endif %}
{% endmacro %}
