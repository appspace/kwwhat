{{
  config(
    materialized='incremental',
    unique_key='id_tag',
    incremental_strategy='merge'
  )
}}

-- Incremental strategy: merge one row per id_tag, including __UNKNOWN__, for drivers with a visit written in the window.
-- Watermark: max(_incremental_ts) in this model; read fact_visits._incremental_ts strictly after it through one bounded window.
-- Reprocessing: reconcile with stored state; a rewritten stored first or last visit takes its new end, otherwise earliest and latest win. No lookback.
-- Late arrivals: extended visits and earlier visits are handled when rewritten. A visit whose visit_id changes leaves the stored end until a rebuild.
-- Special behavior: a visit that gains an inferred id_tag can leave __UNKNOWN__ stale.
-- Windows with no written visits emit no rows and do not advance the watermark; recover per ADR 0008.

with incremental_date_range as (
    {{ incremental_date_range() }}
),

new_visits as (
    select
        coalesce(v.id_tag, '__UNKNOWN__') as id_tag,
        {{ min_by('v.visit_id', 'v.visit_end_ts') }} as first_visit_id,
        {{ max_by('v.visit_id', 'v.visit_end_ts') }} as last_visit_id,
        min(v.visit_end_ts) as first_seen_ts,
        max(v.visit_end_ts) as last_seen_ts,
    from {{ ref('fact_visits') }} as v
    where v._incremental_ts > (select from_timestamp from incremental_date_range)
        and v._incremental_ts <= (select to_timestamp from incremental_date_range)
        and v.visit_end_ts is not null
    group by coalesce(v.id_tag, '__UNKNOWN__')
),

final as (
{% if is_incremental() %}
    select
        v.id_tag,
        case
            when b.first_seen_ts is null or v.first_visit_id = b.first_visit_id or v.first_seen_ts <= b.first_seen_ts
                then v.first_visit_id
            else b.first_visit_id
        end as first_visit_id,
        case
            when b.last_seen_ts is null or v.last_visit_id = b.last_visit_id or v.last_seen_ts >= b.last_seen_ts
                then v.last_visit_id
            else b.last_visit_id
        end as last_visit_id,
        case
            when b.first_seen_ts is null or v.first_visit_id = b.first_visit_id or v.first_seen_ts <= b.first_seen_ts
                then v.first_seen_ts
            else b.first_seen_ts
        end as first_seen_ts,
        case
            when b.last_seen_ts is null or v.last_visit_id = b.last_visit_id or v.last_seen_ts >= b.last_seen_ts
                then v.last_seen_ts
            else b.last_seen_ts
        end as last_seen_ts,
    from new_visits as v
    left join {{ this }} as b
        on v.id_tag = b.id_tag
{% else %}
    select
        v.id_tag,
        v.first_visit_id,
        v.last_visit_id,
        v.first_seen_ts,
        v.last_seen_ts,
    from new_visits as v
{% endif %}
)

select
    id_tag,
    first_visit_id,
    last_visit_id,
    first_seen_ts,
    last_seen_ts,
    (select to_timestamp from incremental_date_range) as _incremental_ts,
from final
