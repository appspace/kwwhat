{{
  config(
    materialized='incremental',
    unique_key='id_tag',
    incremental_strategy='merge'
  )
}}

-- Incremental strategy: merge one row per id_tag, including __UNKNOWN__, overwriting each changed driver.
-- Watermark: max(_incremental_ts) in this model; read fact_visits._incremental_ts strictly after it through one bounded window.
-- Reprocessing: drivers with a visit written in the window are recomputed from their full visit and stopped-attempt history.
-- Late arrivals: earlier stops, extended visits and inferred id_tags are reflected when the affected driver's visit is rewritten.
-- Special behavior: a visit that gains an inferred id_tag leaves __UNKNOWN__ stale until another anonymous visit is written.
-- Windows with no written visits emit no rows and do not advance the watermark; recover per ADR 0008.

with incremental_date_range as (
    {{ incremental_date_range() }}
),

changed_drivers as (
    select distinct
        coalesce(v.id_tag, '__UNKNOWN__') as id_tag,
    from {{ ref('fact_visits') }} as v
    where v._incremental_ts > (select from_timestamp from incremental_date_range)
        and v._incremental_ts <= (select to_timestamp from incremental_date_range)
        and v.visit_end_ts is not null
),

visit_history as (
    select
        coalesce(v.id_tag, '__UNKNOWN__') as id_tag,
        min(v.visit_end_ts) as first_seen_ts,
        max(v.visit_end_ts) as last_seen_ts,
    from {{ ref('fact_visits') }} as v
    inner join changed_drivers as c
        on coalesce(v.id_tag, '__UNKNOWN__') = c.id_tag
    where v.visit_end_ts is not null
    group by coalesce(v.id_tag, '__UNKNOWN__')
),

authorization_history as (
    select
        att.id_tag,
        {{ min_by('att.id_tag_status', 'att.charge_attempt_stop_ts') }} as first_authorization_status,
        {{ max_by('att.id_tag_status', 'att.charge_attempt_stop_ts') }} as latest_authorization_status,
    from {{ ref('fact_charge_attempts') }} as att
    inner join changed_drivers as c
        on att.id_tag = c.id_tag
    where att.charge_attempt_stop_ts is not null
    group by att.id_tag
)

select
    v.id_tag,
    v.first_seen_ts,
    v.last_seen_ts,
    a.first_authorization_status,
    a.latest_authorization_status,
    (select to_timestamp from incremental_date_range) as _incremental_ts,
from visit_history as v
left join authorization_history as a
    on v.id_tag = a.id_tag
