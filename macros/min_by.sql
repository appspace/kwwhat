{% macro min_by(value, order_col) %}
    {{ return(adapter.dispatch('min_by', 'kwwhat')(value, order_col)) }}
{% endmacro %}

{% macro default__min_by(value, order_col) %}
    min_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro bigquery__min_by(value, order_col) %}
    any_value({{ value }} having min {{ order_col }})
{% endmacro %}

{% macro postgres__min_by(value, order_col) %}
    (array_agg({{ value }} order by {{ order_col }}))[1]
{% endmacro %}

# Dont forget to cast from varchar if needed  #
{% macro redshift__min_by(value, order_col) %}
    SPLIT_PART(
        LISTAGG({{ value }}::varchar, CHR(1)) WITHIN GROUP (ORDER BY {{ order_col }} ASC),
        CHR(1),
        1
    )
{% endmacro %}