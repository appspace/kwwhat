{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "connector_id", "port_id"],
    incremental_strategy="merge",
    cluster_by="latest_status_ts"
  )
}}

{%- if is_incremental() -%}
    {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
{%- else -%}
    {%- set from_ts_caps = [
        "cast( '" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")"
    ] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(from_timestamp_caps=from_ts_caps, buffer_minutes=0) }}
),
    source_window as (
        select
            charge_point_id,
            connector_id,
            port_id,
            status,
            error_code,
            ingested_ts,
            max(ingested_ts) over() as incremental_ts
        from {{ ref('int_status_changes') }}
        cross join incremental_date_range
        where next_status is null
            and ingested_ts >= incremental_date_range.from_timestamp
    )

select
    charge_point_id,                                                                                                                                     
    connector_id,   
    port_id,     
    status as latest_status,
    error_code as latest_error_code,
    ingested_ts as latest_status_ts,                                                                                                                                    
    incremental_ts
from source_window
