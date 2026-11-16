-- DuckDB example for the Chat BI demo, not a published Semantic Layer metric.
-- Replace the illustrative bounds with validated timestamps in the source time basis.
-- These demo dates do not establish complete 30-day history; check coverage separately.
-- Requires the stop-based driver-history migration and aligned history rebuild (ADR 0014).
-- Active and prior activity use attempt stops; first_seen_ts is the earliest observed stop.
-- The driver_cohorts CTE has one row per active credential and can be reused for visits.
-- Any history_inconsistent output blocks interpreting the three-way partition.
with parameters as (
    select
        cast('2025-10-12 10:00:00' as timestamp) as period_start_ts,
        cast('2025-10-12 12:00:00' as timestamp) as period_end_ts,
),

period_activity as (
    select
        a.id_tag,
        min(a.charge_attempt_stop_ts) as first_period_activity_ts,
    from analytics.ANALYTICS.fact_charge_attempts as a
    cross join parameters as p
    where a.charge_attempt_stop_ts >= p.period_start_ts
        and a.charge_attempt_stop_ts < p.period_end_ts
        and a.id_tag is not null
        and a.id_tag not in ('UNKNOWN', '__UNKNOWN__')
    group by a.id_tag
),

prior_activity as (
    select
        a.id_tag,
        min(a.charge_attempt_stop_ts) as first_prior_activity_ts,
        max(a.charge_attempt_stop_ts) as last_prior_activity_ts,
    from analytics.ANALYTICS.fact_charge_attempts as a
    inner join period_activity as c
        on a.id_tag = c.id_tag
    cross join parameters as p
    where a.charge_attempt_stop_ts >= p.period_start_ts - interval '30 days'
        and a.charge_attempt_stop_ts < p.period_start_ts
    group by a.id_tag
),

driver_history as (
    select
        d.id_tag,
        min(d.driver_key) as driver_key,
        min(d.first_seen_ts) as first_seen_ts,
        count(*) as dimension_rows,
        sum(case
            when d.is_known_driver
                and d.driver_key is not null
                and d.first_seen_ts is not null
            then 1
            else 0
        end) as valid_dimension_rows,
    from analytics.ANALYTICS.dim_drivers as d
    inner join period_activity as c
        on d.id_tag = c.id_tag
    group by d.id_tag
),

driver_cohorts as (
    select
        h.driver_key,
        c.id_tag,
        p.period_start_ts,
        p.period_end_ts,
        h.first_seen_ts,
        c.first_period_activity_ts,
        a.first_prior_activity_ts,
        a.last_prior_activity_ts,
        case
            when coalesce(h.dimension_rows, 0) != 1
                or coalesce(h.valid_dimension_rows, 0) != 1
                or h.first_seen_ts > c.first_period_activity_ts
                or h.first_seen_ts > a.first_prior_activity_ts
            then 'history_inconsistent'
            when h.first_seen_ts >= p.period_start_ts
            then 'new'
            when a.last_prior_activity_ts is not null
            then 'retained'
            else 'resurrected'
        end as driver_cohort,
    from period_activity as c
    cross join parameters as p
    left join prior_activity as a
        on c.id_tag = a.id_tag
    left join driver_history as h
        on c.id_tag = h.id_tag
)

select
    driver_cohort,
    count(*) as active_driver_count,
from driver_cohorts
group by driver_cohort
order by driver_cohort

