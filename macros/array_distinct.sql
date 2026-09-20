{% macro array_distinct(array_column) %}
    {#
      Platform-invariant array-dedupe. array_distinct() is not a function on every
      adapter (e.g. BigQuery, Postgres, Redshift lack it natively).
      Example: {{ array_distinct('my_array_col') }}.
    #}
    {{ return(adapter.dispatch('array_distinct', 'kwwhat')(array_column)) }}
{% endmacro %}

{% macro default__array_distinct(array_column) %}
    array(select distinct element from unnest({{ array_column }}) as element)
{% endmacro %}

{% macro snowflake__array_distinct(array_column) %}
    array_distinct({{ array_column }})
{% endmacro %}

{% macro bigquery__array_distinct(array_column) %}
    array(select distinct element from unnest({{ array_column }}) as element)
{% endmacro %}

{% macro databricks__array_distinct(array_column) %}
    array_distinct({{ array_column }})
{% endmacro %}

{% macro spark__array_distinct(array_column) %}
    array_distinct({{ array_column }})
{% endmacro %}
