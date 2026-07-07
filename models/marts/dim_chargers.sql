{{
  config(
    materialized='table',
    description='Charger dimension; one row per charger.'
  )
}}

with chargers as (
    select
        charge_point_id,
        location_id,
        commissioned_ts,
        decommissioned_ts,
        port_count
    from {{ ref('int_chargers') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['chargers.charge_point_id']) }} as charge_point_key,
    chargers.charge_point_id,
    chargers.location_id,
    chargers.commissioned_ts,
    chargers.decommissioned_ts,
    chargers.decommissioned_ts is null as is_active,
    chargers.port_count
from chargers
