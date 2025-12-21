{{
  config(
    materialized='table',
    description='Date dimension table for semantic models and date-based joins'
  )
}}

with date_spine as (
    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('2020-01-01' as date)",
        end_date="cast('2050-12-31' as date)"
    ) }}
)

select
    date_day as date_id,
    date_day,
    extract(year from date_day) as year,
    extract(month from date_day) as month,
    extract(day from date_day) as day,
    extract(dayofweek from date_day) as day_of_week,
    extract(quarter from date_day) as quarter,
    {{ dbt.date_trunc('week', 'date_day') }} as week_start_date,
    {{ dbt.date_trunc('month', 'date_day') }} as month_start_date,
    {{ dbt.date_trunc('quarter', 'date_day') }} as quarter_start_date,
    {{ dbt.date_trunc('year', 'date_day') }} as year_start_date
from date_spine

