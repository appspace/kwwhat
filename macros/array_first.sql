{% macro array_first(array_column) %}
    {#
      Array indexing is 0-based on Snowflake/BigQuery/Spark and 1-based on DuckDB.
    #}
    {% if target.type == 'duckdb' %}
        {{ array_column }}[1]
    {% else %}
        {{ array_column }}[0]
    {% endif %}
{% endmacro %}
