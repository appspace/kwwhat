{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "connector_id", "port_id"],
    incremental_strategy="merge",
    cluster_by="latest_status_ts"
  )
}}

select
    charge_point_id,
    connector_id,
    port_id,
    status as latest_status,
    error_code as latest_error_code,
    ingested_ts as latest_status_ts,
    max(ingested_ts) over() as incremental_ts
from {{ ref('int_status_changes') }}
where next_status is null

{%- if is_incremental() -%}
    and ingested_ts >= (select max(incremental_ts) from {{ this }})
{%- else -%}
    and ingested_ts >= cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }})
{%- endif -%}
