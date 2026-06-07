{{
  config(
    materialized='table',
    description='Materialized snapshot of stg_ports. Breaks the live RAW catalog dependency for downstream views and incremental models.'
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
        decommissioned_ts,
    from {{ ref('stg_ports') }}
)

select
    charge_point_id,
    location_id,
    port_id,
    connector_id,
    connector_type,
    commissioned_ts,
    decommissioned_ts,
from ports
