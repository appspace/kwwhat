{% macro max_by(value, order_col) %}
    {{ return(adapter.dispatch('max_by', 'kwwhat')(value, order_col)) }}
{% endmacro %}

{% macro default__max_by(value, order_col) %}
    {{ exceptions.raise_compiler_error(
        "max_by not implemented for adapter " ~ target.type
    ) }}
{% endmacro %}

{% macro snowflake__max_by(value, order_col) %}
    max_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro duckdb__max_by(value, order_col) %}
    max_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro bigquery__max_by(value, order_col) %}
    any_value({{ value }} having max {{ order_col }})
{% endmacro %}

{% macro postgres__max_by(value, order_col) %}
    (array_agg({{ value }} order by {{ order_col }} desc))[1]
{% endmacro %}

{% macro redshift__max_by(value, order_col) %}
    (array_agg({{ value }} order by {{ order_col }} desc))[1]
{% endmacro %}

{% macro trino__max_by(value, order_col) %}
    max_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro presto__max_by(value, order_col) %}
    max_by({{ value }}, {{ order_col }})
{% endmacro %}