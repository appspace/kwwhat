{% macro max_by(value, order_col) %}
    {{ return(adapter.dispatch('max_by', 'kwwhat')(value, order_col)) }}
{% endmacro %}

{% macro default__max_by(value, order_col) %}
    max_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro bigquery__max_by(value, order_col) %}
    any_value({{ value }} having max {{ order_col }})
{% endmacro %}

{% macro postgres__max_by(value, order_col) %}
    (array_agg({{ value }} order by {{ order_col }} desc))[1]
{% endmacro %}

# Dont forget to cast from varchar if needed  #
{% macro redshift__max_by(value, order_col) %}
    SPLIT_PART(
        LISTAGG({{ value }}::varchar, CHR(1)) WITHIN GROUP (ORDER BY {{ order_col }} DESC),
        CHR(1),
        1
    )
{% endmacro %}
