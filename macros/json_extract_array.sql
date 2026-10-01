{% macro json_extract_array(string, string_path) %}
    {#
      Extracts a JSON array (or object) field at string_path, returning each adapter's own
      native "already extracted" array/variant/JSON value - pair with json_array_unnest()
      to unnest it. This is deliberately separate from json_extract(): that macro extracts
      scalars (and, on BigQuery specifically, returns null for arrays/objects - it uses
      json_extract_scalar, which only supports scalar values). Use this one whenever the
      path points at a JSON array, e.g. OCPP's meterValue/sampledValue.
      Example: {{ json_extract_array(payload, 'meterValue') }}
    #}
    {{ return(adapter.dispatch('json_extract_array', 'kwwhat')(string, string_path)) }}
{% endmacro %}

{% macro default__json_extract_array(string, string_path) %}
    cast(json_extract(try_parse_json({{ string }}), '$.{{ string_path }}') as array(json))
{% endmacro %}

{% macro snowflake__json_extract_array(string, string_path) %}
    try_parse_json({{ string }}):{{ string_path }}
{% endmacro %}

{% macro bigquery__json_extract_array(string, string_path) %}
    json_extract_array({{ string }}, '$.{{ string_path }}')
{% endmacro %}

{% macro duckdb__json_extract_array(string, string_path) %}
    json_extract({{ string }}, '$.{{ string_path }}')
{% endmacro %}

{% macro postgres__json_extract_array(string, string_path) %}
    ({{ string }}::jsonb -> '{{ string_path }}')
{% endmacro %}

{% macro redshift__json_extract_array(string, string_path) %}
    ({{ string }}::jsonb -> '{{ string_path }}')
{% endmacro %}
