{{
  config(
    materialized='table',
    description="One row per location. Physical capacity counts derived from int_connectors and int_chargers. Full refresh — counts are overwritten when ports are commissioned or decommissioned."
  )
}}

with connectors as (
    select
        ch.location_id,
        c.charger_id,
        c.port_id,
        c.connector_id
    from {{ ref('int_connectors') }} as c
    left join {{ ref('int_chargers') }} as ch
        on c.charger_id = ch.charger_id
),

capacity as (
    select
        location_id,
        count(distinct charger_id) as charger_count,
        count(distinct charger_id || '|' || cast(port_id as {{ dbt.type_string() }})) as port_count,
        count(
            distinct charger_id
                || '|' || cast(port_id as {{ dbt.type_string() }})
                || '|' || cast(connector_id as {{ dbt.type_string() }})
        ) as connector_count
    from connectors
    group by location_id
)

select
    {{ dbt_utils.generate_surrogate_key(['location_id']) }} as location_key,
    location_id,
    charger_count,
    port_count,
    connector_count
from capacity
