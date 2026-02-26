{{
  config(
    materialized='view',
    description='One row per charge point per day between commissioned and decommissioned, with minutes the charger was commissioned that day. Used for uptime and availability metrics.'
  )
}}

with ports as (
    select
        charge_point_id,
        min(commissioned_ts) as commissioned_ts,
        max(decommissioned_ts) as decommissioned_ts
    from {{ ref('stg_ports') }}
    where commissioned_ts is not null
    group by charge_point_id
),

charge_point_span as (
    select
        charge_point_id,
        commissioned_ts,
        coalesce(decommissioned_ts, {{ dbt.current_timestamp() }}) as decommissioned_ts
    from ports
),

calendar as (
    select date_id
    from {{ ref('dim_dates') }}
),

commissioned_days as (
    select
        c.charge_point_id,
        d.date_id,
        c.commissioned_ts,
        c.decommissioned_ts
    from charge_point_span c
    cross join calendar d
    where d.date_id >= {{ dbt.date_trunc('day', 'c.commissioned_ts') }}
      and d.date_id <= {{ dbt.date_trunc('day', 'c.decommissioned_ts') }}
),

span_bounds as (
    select
        charge_point_id,
        date_id,
        greatest(commissioned_ts, date_id) as span_start,
        least(decommissioned_ts, {{ dbt.dateadd('day', 1, 'date_id') }}) as span_end
    from commissioned_days
),

per_day_minutes as (
    select
        charge_point_id,
        date_id,
        greatest(0, {{ dbt.datediff('span_start', 'span_end', 'minute') }}) as minutes
    from span_bounds
)

select
    charge_point_id,
    date_id,
    minutes
from per_day_minutes
