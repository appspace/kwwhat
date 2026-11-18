{{
  config(
    materialized='table'
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
        -- port_id and connector_id are unique across the network (scoped by charger_id)
        count(distinct port_id) as port_count,
        count(distinct connector_id) as connector_count
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
