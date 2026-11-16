-- Growth accounting subtracts first-seen acquisitions from active-set entrants.
-- Both histories must describe the same known-driver population through the activity watermark.
with first_activity as (
    select
        driver_key,
        min(date_id) as first_activity_date,
    from {{ ref('fact_driver_activity_daily') }}
    group by driver_key
),

known_drivers as (
    select
        driver_key,
        cast(first_seen_ts as date) as first_seen_date,
    from {{ ref('dim_drivers') }}
    where is_known_driver
        and id_tag not in ('UNKNOWN', '__UNKNOWN__')
        and first_seen_ts <= (
            select max(_incremental_ts) from {{ ref('fact_driver_activity_daily') }}
        )
)

select
    coalesce(a.driver_key, d.driver_key) as driver_key,
    a.first_activity_date,
    d.first_seen_date,
from first_activity as a
full outer join known_drivers as d
    on a.driver_key = d.driver_key
where a.driver_key is null
    or d.driver_key is null
    or a.first_activity_date != d.first_seen_date
