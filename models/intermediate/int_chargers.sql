{{
  config(
    materialized='table',
    description='Materialized charger reference table with port count. Breaks the live RAW catalog dependency for downstream models. Grain: one row per charge_point_id.'
  )
}}

with chargers as (
    select
        charge_point_id,
        location_id,
        commissioned_ts,
        decommissioned_ts
    from {{ ref('stg_chargers') }}
),

port_counts as (
    select
        charge_point_id,
        count(port_id) as port_count
    from {{ ref('int_ports') }}
    group by charge_point_id
)

select
    chargers.charge_point_id,
    chargers.location_id,
    chargers.commissioned_ts,
    chargers.decommissioned_ts,
    port_counts.port_count
from chargers
left join port_counts
    on chargers.charge_point_id = port_counts.charge_point_id
