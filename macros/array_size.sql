{% macro array_size(array_column) %}
    {{ return(adapter.dispatch('array_size', 'kwwhat')(array_column)) }}
{% endmacro %}

{% macro default__array_size(array_column) %}
    cardinality({{ array_column }})
{% endmacro %}

{% macro snowflake__array_size(array_column) %}
    array_size({{ array_column }})
{% endmacro %}

{% macro redshift__array_size(array_column) %}
    get_array_length({{ array_column }})
{% endmacro %}

{% macro duckdb__array_size(array_column) %}
    len({{ array_column }})
{% endmacro %}
