{{
  config(
    materialized='table'
  )
}}

with chargers as (
    select
        charger_id,
        location_id,
        commissioned_ts,
        decommissioned_ts
    from {{ ref('stg_chargers') }}
),

port_counts as (
    select
        charger_id,
        count(port_id) as port_count
    from {{ ref('int_ports') }}
    group by charger_id
),

vendor_info as (
    select
        charger_id,
        charge_point_vendor
    from {{ ref('int_charger_vendor_info') }}
)

select
    chargers.charger_id,
    chargers.location_id,
    chargers.commissioned_ts,
    chargers.decommissioned_ts,
    port_counts.port_count,
    vendor_info.charge_point_vendor
from chargers
left join port_counts
    on chargers.charger_id = port_counts.charger_id
left join vendor_info
    on chargers.charger_id = vendor_info.charger_id
