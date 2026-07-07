{{
  config(
    materialized='table',
    description='Materialized charger reference table. Breaks the live RAW catalog dependency for downstream models. Grain: one row per charge_point_id.'
  )
}}

with chargers as (
    select
        charge_point_id,
        location_id,
        commissioned_ts,
        decommissioned_ts
    from {{ ref('stg_chargers') }}
)

select
    charge_point_id,
    location_id,
    commissioned_ts,
    decommissioned_ts
from chargers
