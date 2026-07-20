{{
  config(
    materialized='view',
    description='One row per charger, port, and day: uptime = (minutes commissioned that day minus total outage minutes) / minutes commissioned that day.'
  )
}}

with ports as (
    select
        charger_id,
        port_id
    from {{ ref('dim_ports') }}
),

span_port_days as (
    select
        p.charger_id,
        p.port_id,
        s.date_id,
        s.minutes as minutes_commissioned
    from {{ ref('fact_charger_commissioned_daily') }} as s
    inner join ports as p on s.charger_id = p.charger_id
),

downtime_agg as (
    select
        date_id,
        charger_id,
        port_id,
        sum(duration_minutes) as total_downtime_minutes
    from {{ ref('fact_downtime_daily') }}
    group by date_id, charger_id, port_id
),

with_downtime as (
    select
        s.charger_id,
        s.port_id,
        s.date_id,
        s.minutes_commissioned,
        coalesce(d.total_downtime_minutes, 0) as total_downtime_minutes
    from span_port_days as s
    left join downtime_agg as d
        on s.charger_id = d.charger_id
       and s.port_id = d.port_id
       and s.date_id = d.date_id
),

-- charger_id -> location_id (dim_chargers) -> location_key generated in place
with_location as (
    select
        with_downtime.*,
        chargers.location_id
    from with_downtime
    left join {{ ref('dim_chargers') }} as chargers
        on with_downtime.charger_id = chargers.charger_id
)

select
    {{ dbt_utils.generate_surrogate_key(['charger_id', 'port_id', 'date_id']) }} as uptime_id,
    {{ dbt_utils.generate_surrogate_key(['charger_id', 'port_id']) }} as port_key,
    case when location_id is not null
        then {{ dbt_utils.generate_surrogate_key(['location_id']) }}
    end as location_key,
    charger_id,
    port_id,
    date_id,
    (minutes_commissioned - total_downtime_minutes) / minutes_commissioned as uptime
from with_location
where minutes_commissioned > 0
