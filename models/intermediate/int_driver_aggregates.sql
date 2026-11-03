{{
  config(
    materialized='incremental',
    unique_key='id_tag',
    incremental_strategy='merge'
  )
}}

-- Incremental strategy: merge cumulative stop-time history per id_tag, including __UNKNOWN__.
-- Watermark: max(_incremental_ts) in this model; read updated_ts strictly after it through one bounded window.
-- Reprocessing: reconcile first/latest stops and their authorization statuses with existing state; no lookback.
-- Late arrivals: null-to-stop updates and earlier stops are included when updated_ts enters the window.
-- Corrections that retract a stop or move an existing extreme inward require a rebuild/backfill.
-- Open-only windows emit no rows and do not advance the watermark; recover per ADR 0008.

with incremental_date_range as (
    {{ incremental_date_range() }}
),

attempts as (
    select
        att.id_tag,
        att.id_tag_status,
        att.charge_attempt_stop_ts,
    from {{ ref('fact_charge_attempts') }} as att
    where att.updated_ts > (select from_timestamp from incremental_date_range)
        and att.updated_ts <= (select to_timestamp from incremental_date_range)
        and att.charge_attempt_stop_ts is not null
),

new_aggs as (
    select
        id_tag,
        min(charge_attempt_stop_ts) as first_seen_ts,
        max(charge_attempt_stop_ts) as last_seen_ts,
        {{ min_by('id_tag_status', 'charge_attempt_stop_ts') }} as first_authorization_status,
        {{ max_by('id_tag_status', 'charge_attempt_stop_ts') }} as latest_authorization_status,
    from attempts
    where id_tag is not null
    group by id_tag

    union all

    select
        '__UNKNOWN__' as id_tag,
        min(charge_attempt_stop_ts) as first_seen_ts,
        max(charge_attempt_stop_ts) as last_seen_ts,
        cast(null as {{ dbt.type_string() }}) as first_authorization_status,
        cast(null as {{ dbt.type_string() }}) as latest_authorization_status,
    from attempts
    where id_tag is null
    having count(*) > 0
),

final as (
{% if is_incremental() %}
    select
        n.id_tag,
        case
            when b.first_seen_ts is null or n.first_seen_ts <= b.first_seen_ts
                then n.first_seen_ts
            else b.first_seen_ts
        end as first_seen_ts,
        case
            when b.last_seen_ts is null or n.last_seen_ts >= b.last_seen_ts
                then n.last_seen_ts
            else b.last_seen_ts
        end as last_seen_ts,
        case
            when b.first_seen_ts is null or n.first_seen_ts <= b.first_seen_ts
                then n.first_authorization_status
            else b.first_authorization_status
        end as first_authorization_status,
        case
            when b.last_seen_ts is null or n.last_seen_ts >= b.last_seen_ts
                then n.latest_authorization_status
            else b.latest_authorization_status
        end as latest_authorization_status,
    from new_aggs as n
    left join {{ this }} as b on n.id_tag = b.id_tag
{% else %}
    select
        id_tag,
        first_seen_ts,
        last_seen_ts,
        first_authorization_status,
        latest_authorization_status,
    from new_aggs
{% endif %}
)

select
    id_tag,
    first_seen_ts,
    last_seen_ts,
    first_authorization_status,
    latest_authorization_status,
    (select to_timestamp from incremental_date_range) as _incremental_ts,
from final
