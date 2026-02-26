{{
  config(
    materialized='view',
    description='One row per charge point, port, and day: uptime = (minutes commissioned that day minus total outage minutes) / minutes commissioned that day.'
  )
}}

with ports as (
    select distinct charge_point_id, port_id
    from {{ ref('stg_ports') }}
),

span_port_days as (
    select
        p.charge_point_id,
        p.port_id,
        s.date_id,
        s.minutes as minutes_commissioned
    from {{ ref('charge_point_span_daily') }} s
    join ports p on s.charge_point_id = p.charge_point_id
),

downtime_agg as (
    select
        date_id,
        charge_point_id,
        port_id,
        sum(duration_minutes) as total_downtime_minutes
    from {{ ref('fact_downtime_daily') }}
    group by date_id, charge_point_id, port_id
),

with_downtime as (
    select
        s.charge_point_id,
        s.port_id,
        s.date_id,
        s.minutes_commissioned,
        coalesce(d.total_downtime_minutes, 0) as total_downtime_minutes
    from span_port_days s
    left join downtime_agg d
        on s.charge_point_id = d.charge_point_id
       and s.port_id = d.port_id
       and s.date_id = d.date_id
)

select
    {{ dbt_utils.generate_surrogate_key(['charge_point_id', 'port_id', 'date_id']) }} as uptime_id,
    charge_point_id,
    port_id,
    date_id,
    (minutes_commissioned - total_downtime_minutes) / minutes_commissioned as uptime
from with_downtime
where minutes_commissioned > 0
