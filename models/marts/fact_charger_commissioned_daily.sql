{{
  config(
    materialized='view'
  )
}}

with chargers as (
    select
        charger_id,
        commissioned_ts,
        decommissioned_ts
    from {{ ref('int_chargers') }}
    where commissioned_ts is not null
),

charger_commissioned_span as (
    select
        charger_id,
        commissioned_ts,
        coalesce(decommissioned_ts, {{ dbt.current_timestamp() }}) as decommissioned_ts
    from chargers
),

calendar as (
    select date_id
    from {{ ref('dim_dates') }}
),

commissioned_days as (
    select
        c.charger_id,
        d.date_id,
        c.commissioned_ts,
        c.decommissioned_ts
    from charger_commissioned_span as c
    cross join calendar as d
    where d.date_id >= cast(c.commissioned_ts as date)
      and d.date_id <= cast(c.decommissioned_ts as date)
),

span_bounds as (
    select
        charger_id,
        date_id,
        -- date_id is DATE; cast so it compares with the timestamps on every warehouse
        greatest(commissioned_ts, cast(date_id as {{ dbt.type_timestamp() }})) as span_start,
        least(decommissioned_ts, {{ timestamp_add('day', 1, 'date_id') }}) as span_end
    from commissioned_days
),

per_day_minutes as (
    select
        charger_id,
        date_id,
        greatest(0, {{ dbt.datediff('span_start', 'span_end', 'minute') }}) as minutes
    from span_bounds
)

select
    charger_id,
    date_id,
    minutes
from per_day_minutes
where minutes > 0
