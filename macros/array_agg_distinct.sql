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

{#
  Contract on every adapter: duplicates removed AND null elements dropped. field_to_agg
  (e.g. connector_id, id_tag) is legitimately null on some rows, and downstream logic
  (array_first(), array_size() counts) assumes the array holds only real values.
  Snowflake's array_agg already skips nulls; the adapters below need it done explicitly.
  Covered by unit test test_transactions_id_tags_drop_nulls_and_duplicates.
#}
{% macro bigquery__array_agg_distinct(field_to_agg) %}
    {# BigQuery also refuses to write an array containing a null ("Array cannot have a null element"). #}
    array_agg(distinct {{ field_to_agg }} ignore nulls)
{% endmacro %}

{% macro duckdb__array_agg_distinct(field_to_agg) %}
    {# DuckDB's array_agg keeps nulls; list_distinct removes both duplicates and nulls. #}
    list_distinct(array_agg({{ field_to_agg }}))
{% endmacro %}

{% macro postgres__array_agg_distinct(field_to_agg) %}
    {# Postgres's array_agg keeps nulls; array_remove drops them (and returns {} when every value is null). #}
    array_remove(array_agg(distinct {{ field_to_agg }}), null)
{% endmacro %}
