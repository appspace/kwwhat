{{
  config(
    materialized='table',
    description='Materialized connector reference table. Breaks the live RAW catalog dependency for downstream models. Grain: one row per charger_id + port_id + connector_id.'
  )
}}

with connectors as (
    select
        charger_id,
        port_id,
        connector_id,
        connector_type
    from {{ ref('stg_connectors') }}
)

select
    charger_id,
    port_id,
    connector_id,
    connector_type
from connectors
