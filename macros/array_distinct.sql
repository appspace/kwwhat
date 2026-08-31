{% macro array_distinct(array_column) %}
    {#
      Platform-invariant array deduplication.
      Example: {{ array_distinct('my_array_col') }}
    #}
    {{ return(adapter.dispatch('array_distinct', 'kwwhat')(array_column)) }}
{% endmacro %}

{% macro default__array_distinct(array_column) %}
    array_distinct({{ array_column }})
{% endmacro %}

{% macro bigquery__array_distinct(array_column) %}
    {#
      BigQuery has no array_distinct() function (it has array_is_distinct(), which returns
      a bool, not an array) - de-duplicate via unnest + distinct instead.
    #}
    array(select distinct x from unnest({{ array_column }}) as x)
{% endmacro %}
