{% macro array_concat_agg_distinct(field_to_agg) %}
    {{ return(adapter.dispatch('array_concat_agg_distinct', 'kwwhat')(field_to_agg)) }}
{% endmacro %}

{% macro default__array_concat_agg_distinct(field_to_agg) %}
    array_distinct(array_concat_agg(coalesce({{ field_to_agg }}, [])))
{% endmacro %}

{% macro snowflake__array_concat_agg_distinct(field_to_agg) %}
    array_distinct(array_flatten(array_agg(coalesce({{ field_to_agg }}, array_construct()))))
{% endmacro %}

{% macro bigquery__array_concat_agg_distinct(field_to_agg) %}
    array(select distinct concatenated_element from unnest(array_concat_agg(coalesce({{ field_to_agg }}, []))) as concatenated_element)
{% endmacro %}
