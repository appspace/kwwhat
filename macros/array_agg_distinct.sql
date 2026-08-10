{% macro array_agg_distinct(field_to_agg) %}
    {#
      Aggregates a column into a deduplicated array in one pass.
      Example: {{ array_agg_distinct('id_tag') }}

      Deliberately not array_distinct(fivetran_utils.array_agg(field_to_agg=...)): on
      BigQuery, unnest() can't take an aggregate function as its argument ("Aggregate
      function ARRAY_AGG not allowed in UNNEST"), so composing array_agg() with a separate
      dedup step fails there. array_agg(distinct ...) does both in a single aggregate call
      and works across adapters.
    #}
    {{ return(adapter.dispatch('array_agg_distinct', 'kwwhat')(field_to_agg)) }}
{% endmacro %}

{% macro default__array_agg_distinct(field_to_agg) %}
    array_agg(distinct {{ field_to_agg }})
{% endmacro %}

{% macro redshift__array_agg_distinct(field_to_agg) %}
    listagg(distinct {{ field_to_agg }}, ',')
{% endmacro %}

{% macro bigquery__array_agg_distinct(field_to_agg) %}
    {#
      BigQuery arrays can't contain a null element when written to a table ("Array cannot
      have a null element"), and field_to_agg (e.g. connector_id, id_tag) can legitimately
      be null on some rows - ignore nulls so a null-containing group still writes. Other
      adapters tolerate null array elements, so this is BigQuery-specific; a group whose
      only value is null returns an empty array here vs. array[null] elsewhere.
    #}
    array_agg(distinct {{ field_to_agg }} ignore nulls)
{% endmacro %}
