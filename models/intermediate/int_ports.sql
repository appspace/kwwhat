{{
  config(
    materialized='table',
    description='Materialized port reference table. Breaks the live RAW catalog dependency for downstream models. Grain: one row per charge_point_id + port_id.'
  )
}}

with ports as (
    select
        charge_point_id,
        port_id
    from {{ ref('stg_ports') }}
),

connector_counts as (
    select
        charge_point_id,
        port_id,
        count(connector_id) as connector_count
    from {{ ref('int_connectors') }}
    group by
        charge_point_id,
        port_id
)

select
    ports.charge_point_id,
    ports.port_id,
    coalesce(connector_counts.connector_count, 0) as connector_count
from ports
left join connector_counts
    on ports.charge_point_id = connector_counts.charge_point_id
    and ports.port_id = connector_counts.port_id
