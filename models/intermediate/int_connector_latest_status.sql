{{
  config(
    materialized='view'
  )
}}

select
    charge_point_id,
    connector_id,
    status as latest_status,
    error_code as latest_error_code,
    ingested_ts as latest_status_ts
from {{ ref('int_status_changes') }}
where next_status is null
