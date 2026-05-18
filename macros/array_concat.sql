{% macro array_concat(array_a, array_b) %}
    {#
      Null-aware concat:
      - both NULL  -> NULL
      - a NULL     -> b
      - b NULL     -> a
      - else       -> concat(a, b)
      Example: {{ array_concat('a_col', 'b_col') }}.
    #}
    case
        when {{ array_a }} is null and {{ array_b }} is null then null
        when {{ array_a }} is null then {{ array_b }}
        when {{ array_b }} is null then {{ array_a }}
        else {{ adapter.dispatch('array_concat_expr', 'kwwhat')(array_a, array_b) }}
    end
{% endmacro %}

{% macro default__array_concat_expr(array_a, array_b) %}
    concat({{ array_a }}, {{ array_b }})
{% endmacro %}

{% macro snowflake__array_concat_expr(array_a, array_b) %}
    array_cat({{ array_a }}, {{ array_b }})
{% endmacro %}

{% macro postgres__array_concat_expr(array_a, array_b) %}
    array_cat({{ array_a }}, {{ array_b }})
{% endmacro %}

{% macro redshift__array_concat_expr(array_a, array_b) %}
    array_cat({{ array_a }}, {{ array_b }})
{% endmacro %}

{% macro bigquery__array_concat_expr(array_a, array_b) %}
    array_concat({{ array_a }}, {{ array_b }})
{% endmacro %}

{% macro spark__array_concat_expr(array_a, array_b) %}
    array_concat({{ array_a }}, {{ array_b }})
{% endmacro %}

{% macro databricks__array_concat_expr(array_a, array_b) %}
    array_concat({{ array_a }}, {{ array_b }})
{% endmacro %}

{% macro duckdb__array_concat_expr(array_a, array_b) %}
    list_concat({{ array_a }}, {{ array_b }})
{% endmacro %}
