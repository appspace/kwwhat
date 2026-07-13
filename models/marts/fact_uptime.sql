{{
  config(
    materialized='view',
    description='One row per charger, port, and day: uptime = (minutes commissioned that day minus total outage minutes) / minutes commissioned that day.'
  )
}}

with ports as (
    select
        port_key,
        charger_id,
        port_id
    from {{ ref('dim_ports') }}
),

span_port_days as (
    select
        p.charger_id,
        p.port_key,
        p.port_id,
        s.date_id,
        s.minutes as minutes_commissioned
    from {{ ref('fact_charger_commissioned_daily') }} as s
    inner join ports as p on s.charger_id = p.charger_id
),

downtime_agg as (
    select
        date_id,
        port_key,
        sum(duration_minutes) as total_downtime_minutes
    from {{ ref('fact_downtime_daily') }}
    group by date_id, port_key
),

with_downtime as (
    select
        s.charger_id,
        s.port_key,
        s.port_id,
        s.date_id,
        s.minutes_commissioned,
        coalesce(d.total_downtime_minutes, 0) as total_downtime_minutes
    from span_port_days as s
    left join downtime_agg as d
        on s.port_key = d.port_key
       and s.date_id = d.date_id
),

-- charger_id -> location_id (dim_chargers) -> location_key (dim_locations)
with_location as (
    select
        with_downtime.*,
        locations.location_key
    from with_downtime
    left join {{ ref('dim_chargers') }} as chargers
        on with_downtime.charger_id = chargers.charger_id
    left join {{ ref('dim_locations') }} as locations
        on chargers.location_id = locations.location_id
)

select
    {{ dbt_utils.generate_surrogate_key(['charger_id', 'port_id', 'date_id']) }} as uptime_id,
    port_key,
    location_key,
    charger_id,
    port_id,
    date_id,
    (minutes_commissioned - total_downtime_minutes) / minutes_commissioned as uptime
from with_location
where minutes_commissioned > 0
