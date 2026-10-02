{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        charger_id,
        port_id,
        max_power_kw
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
    ports.max_power_kw,
    connector_counts.connector_count
from ports
left join connector_counts
    on ports.charger_id = connector_counts.charger_id
    and ports.port_id = connector_counts.port_id
