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
        count(*) over (partition by charge_point_id) as connector_count,
        count(distinct port_id) over (partition by charge_point_id) as port_count,
        count(distinct charge_point_id) over (partition by location_id) as charge_point_count
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
    connector_count,
    port_count,
    charge_point_count,
    connector_count > 1 as has_multiple_connectors
from ports
