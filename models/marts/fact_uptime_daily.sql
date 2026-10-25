{{
  config(
    materialized='view'
  )
}}

with ports as (
    select
        charger_id,
        port_id
    from {{ ref('int_ports') }}
),

span_port_days as (
    select
        p.charger_id,
        p.port_id,
        s.date_id,
        s.commissioned_minutes
    from {{ ref('int_charger_commissioned_daily') }} as s
    inner join ports as p on s.charger_id = p.charger_id
),

downtime_agg as (
    select
        date_id,
        charger_id,
        port_id,
        sum(duration_minutes) as downtime_minutes,
        sum(case when downtime_type = 'OFFLINE' then duration_minutes else 0 end) as offline_downtime_minutes,
        sum(case when downtime_type = 'FAULTED' then duration_minutes else 0 end) as faulted_downtime_minutes
    from {{ ref('fact_downtime_daily') }}
    group by date_id, charger_id, port_id
),

with_downtime as (
    select
        s.charger_id,
        s.port_id,
        s.date_id,
        s.commissioned_minutes,
        coalesce(d.downtime_minutes, 0) as downtime_minutes,
        coalesce(d.offline_downtime_minutes, 0) as offline_downtime_minutes,
        coalesce(d.faulted_downtime_minutes, 0) as faulted_downtime_minutes
    from span_port_days as s
    left join downtime_agg as d
        on s.charger_id = d.charger_id
       and s.port_id = d.port_id
       and s.date_id = d.date_id
),

-- charger_id -> location_id (int_chargers) -> location_key generated in place
with_location as (
    select
        with_downtime.charger_id,
        with_downtime.port_id,
        with_downtime.date_id,
        with_downtime.commissioned_minutes,
        with_downtime.downtime_minutes,
        with_downtime.offline_downtime_minutes,
        with_downtime.faulted_downtime_minutes,
        chargers.location_id
    from with_downtime
    left join {{ ref('int_chargers') }} as chargers
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
    commissioned_minutes,
    downtime_minutes,
    offline_downtime_minutes,
    faulted_downtime_minutes,
    commissioned_minutes - downtime_minutes as uptime_minutes,
    (commissioned_minutes - downtime_minutes) / commissioned_minutes as uptime
from with_location
where commissioned_minutes > 0
