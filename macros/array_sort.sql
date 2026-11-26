{% macro array_sort(array_column) %}
    {#
      Platform-invariant ascending sort of an array, so array contents come out in a
      deterministic order. array_distinct and array_agg do not guarantee element order.
      Example: {{ array_sort('my_array_col') }}.
    #}
    {{ return(adapter.dispatch('array_sort', 'kwwhat')(array_column)) }}
{% endmacro %}

{% macro default__array_sort(array_column) %}
    array(select element from unnest({{ array_column }}) as element order by element)
{% endmacro %}

{% macro snowflake__array_sort(array_column) %}
    array_sort({{ array_column }})
{% endmacro %}

{% macro bigquery__array_sort(array_column) %}
    array(select element from unnest({{ array_column }}) as element order by element)
{% endmacro %}

{% macro databricks__array_sort(array_column) %}
    array_sort({{ array_column }})
{% endmacro %}

{% macro spark__array_sort(array_column) %}
    array_sort({{ array_column }})
{% endmacro %}

{% macro duckdb__array_sort(array_column) %}
    list_sort({{ array_column }})
{% endmacro %}
