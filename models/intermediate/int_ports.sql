{{
  config(
    materialized='table',
    description='Materialized port reference table. Breaks the live RAW catalog dependency for downstream models. Grain: one row per charger_id + port_id.'
  )
}}

with ports as (
    select
        charger_id,
        port_id
    from {{ ref('stg_ports') }}
),

connector_counts as (
    select
        charger_id,
        port_id,
        count(connector_id) as connector_count
    from {{ ref('int_connectors') }}
    group by
        charger_id,
        port_id
)

select
    ports.charger_id,
    ports.port_id,
    connector_counts.connector_count
from ports
left join connector_counts
    on ports.charger_id = connector_counts.charger_id
    and ports.port_id = connector_counts.port_id
