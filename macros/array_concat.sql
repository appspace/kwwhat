{% macro array_concat(array_a, array_b) %}
    {#
      Null-aware concat:
      - both NULL  -> NULL
      - a NULL     -> b
      - b NULL     -> a
      - else       -> concat(a,b)
      Example: {{ array_concat('a_col', 'b_col') }}.
    #}
    {% if target.type == "snowflake" %}
        {% set _concat = "array_cat(" ~ array_a ~ ", " ~ array_b ~ ")" %}
    {% elif target.type in ["postgres", "redshift"] %}
        {% set _concat = "array_cat(" ~ array_a ~ ", " ~ array_b ~ ")" %}
    {% elif target.type == "bigquery" %}
        {% set _concat = "array_concat(" ~ array_a ~ ", " ~ array_b ~ ")" %}
    {% elif target.type in ["spark", "databricks"] %}
        {% set _concat = "array_concat(" ~ array_a ~ ", " ~ array_b ~ ")" %}
    {% elif target.type in ["trino", "presto", "athena"] %}
        {% set _concat = "concat(" ~ array_a ~ ", " ~ array_b ~ ")" %}
    {% elif target.type == "duckdb" %}
        {% set _concat = "list_concat(" ~ array_a ~ ", " ~ array_b ~ ")" %}
    {% else %} 
        {% set _concat = "concat(" ~ array_a ~ ", " ~ array_b ~ ")" %}
    {% endif %}

    case
        when {{ array_a }} is null and {{ array_b }} is null
            then null
        when {{ array_a }} is null
            then {{ array_b }}
        when {{ array_b }} is null
            then {{ array_a }}
        else {{ _concat }}
    end
{% endmacro %}
