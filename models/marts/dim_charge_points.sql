{{
  config(
    materialized='table',
    description='Charge point dimension; one row per charge point.'
  )
}}

with chargers as (
    select
        charge_point_id,
        location_id,
        commissioned_ts,
        decommissioned_ts
    from {{ ref('int_chargers') }}
),

port_counts as (
    select
        charge_point_id,
        count(distinct port_id) as port_count
    from {{ ref('int_ports') }}
    group by charge_point_id
)

select
    {{ dbt_utils.generate_surrogate_key(['chargers.charge_point_id']) }} as charge_point_key,
    chargers.charge_point_id,
    chargers.location_id,
    chargers.commissioned_ts,
    chargers.decommissioned_ts,
    chargers.decommissioned_ts is null as is_active,
    port_counts.port_count
from chargers
left join port_counts
    on chargers.charge_point_id = port_counts.charge_point_id
