{% macro array_contains(array_column, value) %}
    {#
      Platform-invariant array contains function.
      Example: {{ array_contains('my_array_col', 'search_value') }}
    #}
    {{ adapter.dispatch('array_contains', 'kwwhat')(array_column, value) }}
{% endmacro %}

{% macro default__array_contains(array_column, value) %}
{{ value }} = any({{ array_column }})
{% endmacro %}

{% macro snowflake__array_contains(array_column, value) %}
array_contains({{ value }}::variant, {{ array_column }})
{% endmacro %}

{% macro postgres__array_contains(array_column, value) %}
{{ value }} = any({{ array_column }})
{% endmacro %}

{% macro redshift__array_contains(array_column, value) %}
{{ value }} = any({{ array_column }})
{% endmacro %}

{% macro bigquery__array_contains(array_column, value) %}
{{ value }} in unnest({{ array_column }})
{% endmacro %}

{% macro spark__array_contains(array_column, value) %}
array_contains({{ array_column }}, {{ value }})
{% endmacro %}

{% macro databricks__array_contains(array_column, value) %}
array_contains({{ array_column }}, {{ value }})
{% endmacro %}

{% macro trino__array_contains(array_column, value) %}
contains({{ array_column }}, {{ value }})
{% endmacro %}

{% macro presto__array_contains(array_column, value) %}
contains({{ array_column }}, {{ value }})
{% endmacro %}

{% macro athena__array_contains(array_column, value) %}
contains({{ array_column }}, {{ value }})
{% endmacro %}

{% macro duckdb__array_contains(array_column, value) %}
list_contains({{ array_column }}, {{ value }})
{% endmacro %}
