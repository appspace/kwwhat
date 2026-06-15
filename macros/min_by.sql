{% macro min_by(value, order_col) %}
    {{ return(adapter.dispatch('min_by', 'kwwhat')(value, order_col)) }}
{% endmacro %}

{% macro default__min_by(value, order_col) %}
    {{ exceptions.raise_compiler_error(
        "min_by not implemented for adapter " ~ target.type
    ) }}
{% endmacro %}

{% macro snowflake__min_by(value, order_col) %}
    min_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro duckdb__min_by(value, order_col) %}
    min_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro bigquery__min_by(value, order_col) %}
    any_value({{ value }} having min {{ order_col }})
{% endmacro %}

{% macro postgres__min_by(value, order_col) %}
    (array_agg({{ value }} order by {{ order_col }}))[1]
{% endmacro %}

{% macro redshift__min_by(value, order_col) %}
    (array_agg({{ value }} order by {{ order_col }}))[1]
{% endmacro %}

{% macro trino__min_by(value, order_col) %}
    min_by({{ value }}, {{ order_col }})
{% endmacro %}

{% macro presto__min_by(value, order_col) %}
    min_by({{ value }}, {{ order_col }})
{% endmacro %}