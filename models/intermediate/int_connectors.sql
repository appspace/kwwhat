{{
  config(
    materialized='table'
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
