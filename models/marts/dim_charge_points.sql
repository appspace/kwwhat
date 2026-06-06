{{
  config(
    materialized='table',
    description='Charge point dimension; one row per charge point.'
  )
}}

with ports as (
    select distinct
        charge_point_id,
        location_id,
        commissioned_ts,
        decommissioned_ts,
        port_count,
        connector_count,
    from {{ ref('int_ports') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['ports.charge_point_id']) }} as charge_point_key,
    ports.charge_point_id,
    ports.location_id,
    ports.commissioned_ts,
    ports.decommissioned_ts,
    ports.port_count,
    ports.connector_count,
    ports.decommissioned_ts is null as is_active,
from ports