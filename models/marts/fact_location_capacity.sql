{{
  config(
    materialized='table',
    description="One row per location. Physical capacity counts derived from int_ports. Full refresh — counts are overwritten when ports are commissioned or decommissioned."
  )
}}

with ports as (
    select
        location_id,
        charge_point_id,
        port_id,
        connector_id
    from {{ ref('int_ports') }}
),

capacity as (
    select
        location_id,
        count(distinct charge_point_id) as charge_point_count,
        count(distinct charge_point_id || '|' || cast(port_id as varchar)) as port_count,
        count(distinct charge_point_id || '|' || cast(port_id as varchar) || '|' || cast(connector_id as varchar)) as connector_count
    from ports
    group by location_id
)

select
    {{ dbt_utils.generate_surrogate_key(['location_id']) }} as location_key,
    location_id,
    charge_point_count,
    port_count,
    connector_count
from capacity
