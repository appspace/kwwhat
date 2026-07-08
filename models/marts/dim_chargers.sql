{{
  config(
    materialized='table',
    description='Charger (Charging Station) dimension. One row per Charger. A Charger is the physical system a driver perceives as a single charger — it has one or more Ports. Use for charger inventory, offline outage attribution, and visit attribution at charger level. Sanity check: if a driver says "I went to charger #3", they mean this entity.'
  )
}}

with chargers as (
    select
        charger_id,
        location_id,
        commissioned_ts,
        decommissioned_ts,
        port_count
    from {{ ref('int_chargers') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['chargers.charger_id']) }} as charger_key,
    chargers.charger_id,
    chargers.location_id,
    chargers.commissioned_ts,
    chargers.decommissioned_ts,
    chargers.decommissioned_ts is null as is_commissioned,
    chargers.port_count
from chargers
