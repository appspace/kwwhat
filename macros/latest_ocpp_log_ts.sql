{#
    The timestamp of the latest OCPP log: the end of the data. Null when there are no logs.
#}
{% macro latest_ocpp_log_ts() -%}
    (select max(ingested_timestamp) from {{ ref('stg_ocpp_logs') }})
{%- endmacro %}
