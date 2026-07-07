{{
  config(
    materialized='table',
    description='Materialized connector reference table. Breaks the live RAW catalog dependency for downstream models. Grain: one row per charge_point_id + port_id + connector_id.'
  )
}}

with connectors as (
    select
        charge_point_id,
        port_id,
        connector_id,
        connector_type,
        max_power_kw
    from {{ ref('stg_connectors') }}
)

select
    charge_point_id,
    port_id,
    connector_id,
    connector_type,
    max_power_kw
from connectors
