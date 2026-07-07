{{
  config(
    materialized='table',
    description="One row per location. Physical capacity counts derived from int_connectors and int_chargers. Full refresh — counts are overwritten when ports are commissioned or decommissioned."
  )
}}

with connectors as (
    select
        ch.location_id,
        c.charge_point_id,
        c.port_id,
        c.connector_id
    from {{ ref('int_connectors') }} as c
    left join {{ ref('int_chargers') }} as ch
        on c.charge_point_id = ch.charge_point_id
),

capacity as (
    select
        location_id,
        count(distinct charge_point_id) as charge_point_count,
        count(distinct charge_point_id || '|' || cast(port_id as {{ dbt.type_string() }})) as port_count,
        count(
            distinct charge_point_id
                || '|' || cast(port_id as {{ dbt.type_string() }})
                || '|' || cast(connector_id as {{ dbt.type_string() }})
        ) as connector_count
    from connectors
    group by location_id
)

select
    {{ dbt_utils.generate_surrogate_key(['location_id']) }} as location_key,
    location_id,
    charge_point_count,
    port_count,
    connector_count
from capacity
