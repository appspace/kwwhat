{{
  config(
    materialized='incremental',
    unique_key=["charger_id", "connector_id", "port_id"],
    incremental_strategy="merge",
    cluster_by="latest_status_ts"
  )
}}

-- Incremental strategy: merge one current snapshot per charger_id + connector_id + port_id.
-- Watermark: the shared warehouse checkpoint supplies the bounded processing window.
-- Reprocessing: no lookback or target-state join is used; dbt's merge replaces the snapshot for each connector key.
-- Only int_status_changes rows with next_status is null are eligible, so the output represents current open states.


with incremental_date_range as (
    {{ incremental_date_range() }}
),

source_window as (
    select
        charger_id,
        connector_id,
        port_id,
        status,
        error_code_name,
        error_code,
        taxonomy,
        info,
        ingested_ts,
        max(ingested_ts) over () as incremental_ts
    from {{ ref('int_status_changes') }}
    cross join incremental_date_range
    where next_status is null
        and ingested_ts >= incremental_date_range.from_timestamp
        and ingested_ts <= incremental_date_range.to_timestamp

)

select
    charger_id,
    connector_id,
    port_id,
    status as latest_status,
    error_code_name as latest_error_code_name,
    error_code as latest_error_code,
    taxonomy as latest_taxonomy,
    info as latest_info,
    ingested_ts as latest_status_ts,
    incremental_ts
from source_window
