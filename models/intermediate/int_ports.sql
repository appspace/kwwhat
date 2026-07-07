{{
  config(
    materialized='table',
    description='Materialized port reference table. Breaks the live RAW catalog dependency for downstream models. Grain: one row per charge_point_id + port_id.'
  )
}}

with ports as (
    select
        charge_point_id,
        port_id,
        max_power_kw
    from {{ ref('stg_ports') }}
)

select
    charge_point_id,
    port_id,
    max_power_kw
from ports
