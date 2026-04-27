{% macro json_extract(string, string_path) %}
    {{ return(adapter.dispatch('json_extract', 'kwwhat')(string, string_path)) }}
{% endmacro %}

{% macro default__json_extract(string, string_path) %}
    json_extract_path_text({{ string }}, '{{ string_path }}')
{% endmacro %}

{% macro duckdb__json_extract(string, string_path) %}
    {#
      json_extract_string returns null for objects/arrays (only works for scalars).
      coalesce with json_extract::VARCHAR as fallback covers object/array payloads.
    #}
    {%- set path_str = string_path | string | trim -%}
    {%- if path_str.startswith('[') -%}
        coalesce(json_extract_string({{ string }}, '${{ path_str }}'), json_extract({{ string }}, '${{ path_str }}')::VARCHAR)
    {%- else -%}
        coalesce(json_extract_string({{ string }}, '$.{{ path_str }}'), json_extract({{ string }}, '$.{{ path_str }}')::VARCHAR)
    {%- endif -%}
{% endmacro %}

{% macro snowflake__json_extract(string, string_path) %}
    json_extract_path_text(try_parse_json({{ string }}), '{{ string_path }}')
{% endmacro %}

{% macro bigquery__json_extract(string, string_path) %}
    json_extract_scalar({{ string }}, '$.{{ string_path }}')
{% endmacro %}

{% macro redshift__json_extract(string, string_path) %}
    case when is_valid_json({{ string }}) then json_extract_path_text({{ string }}, '{{ string_path }}') else null end
{% endmacro %}

{% macro postgres__json_extract(string, string_path) %}
    {{ string }}::json->>'{{ string_path }}'
{% endmacro %}
