{{
  config(
    materialized='table',
    description='Charge point dimension; one row per charge point.'
  )
}}

with ports as (
    select
        charge_point_id,
        location_id,
        commissioned_ts,
        decommissioned_ts,
        count(distinct port_id) as port_count
    from {{ ref('int_ports') }}
    group by
        charge_point_id,
        location_id,
        commissioned_ts,
        decommissioned_ts
)

select
    {{ dbt_utils.generate_surrogate_key(['ports.charge_point_id']) }} as charge_point_key,
    ports.charge_point_id,
    ports.location_id,
    ports.commissioned_ts,
    ports.decommissioned_ts,
    ports.decommissioned_ts is null as is_active,
    ports.port_count
from ports
