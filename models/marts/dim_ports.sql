{{
  config(
    materialized='table',
    description='Port/connector dimension; full refresh from stg_ports'
  )
}}

with ports as (
    select
        charge_point_id,
        location_id,
        port_id,
        connector_id,
        connector_type,
        commissioned_ts,
        decommissioned_ts
    from {{ ref('stg_ports') }}
),

latest_status as (
    select
        charge_point_id,
        connector_id,
        status as latest_status,
        error_code as latest_error_code,
        ingested_ts as latest_status_ts
    from {{ ref('int_status_changes') }}
    where next_status is null
)

select
    ports.charge_point_id,
    ports.location_id,
    ports.port_id,
    ports.connector_id,
    ports.connector_type,
    ports.commissioned_ts,
    ports.decommissioned_ts,
    latest_status.latest_status,
    latest_status.latest_error_code,
    latest_status.latest_status_ts
from ports
left join latest_status
    on ports.charge_point_id = latest_status.charge_point_id
    and ports.connector_id = latest_status.connector_id
