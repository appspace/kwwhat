{{
    config(
        materialized='incremental',
        unique_key='driver_activity_id',
        incremental_strategy='merge'
    )
}}

-- Incremental strategy: merge one presence row per known driver and attempt-stop date.
-- Watermark: max(_incremental_ts) in this model; read updated_ts strictly after it through one bounded window.
-- Reprocessing: deduplicate changed stopped attempts by driver/date; repeated stops merge into the same key.
-- Late arrivals: null-to-stop updates and older stop dates are included when updated_ts enters the window.
-- Stop-date corrections, retractions, or driver reassignment require a rebuild/backfill to remove stale presence.
-- Open-only/unidentified windows emit no rows and do not advance the watermark; recover per ADR 0008.

with incremental_date_range as (
    {{ incremental_date_range() }}
),

changed_activity as (
    select
        att.id_tag,
        cast(att.charge_attempt_stop_ts as date) as date_id,
    from {{ ref('fact_charge_attempts') }} as att
    where att.updated_ts > (select from_timestamp from incremental_date_range)
        and att.updated_ts <= (select to_timestamp from incremental_date_range)
        and att.charge_attempt_stop_ts is not null
        and att.id_tag is not null
        and att.id_tag not in ('__UNKNOWN__', 'UNKNOWN')
),

driver_days as (
    select
        id_tag,
        date_id,
    from changed_activity
    group by
        id_tag,
        date_id
)

select
    {{ dbt_utils.generate_surrogate_key(['id_tag', 'date_id']) }} as driver_activity_id,
    {{ dbt_utils.generate_surrogate_key(['id_tag']) }} as driver_key,
    date_id,
    (select to_timestamp from incremental_date_range) as _incremental_ts,
from driver_days
