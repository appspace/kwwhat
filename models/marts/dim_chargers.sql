-- SCD Type 1
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
