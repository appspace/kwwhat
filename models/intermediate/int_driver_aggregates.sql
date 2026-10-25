{{
  config(
    materialized='incremental',
    unique_key='id_tag',
    incremental_strategy='merge'
  )
}}

-- Incremental strategy: merge one cumulative row per id_tag, including the __UNKNOWN__ sentinel.
-- Watermark: the shared warehouse checkpoint supplies the bounded processing window.
-- Reprocessing: the existing row supplies prior first/latest values, while timestamp comparisons select the correct
-- authorization status. Earlier business events are supported when their upstream incremental_ts is newer.
-- The configured 30-minute buffer is not used by the current source filter.


with incremental_date_range as (
    {{ incremental_date_range(buffer_minutes=30) }}
),

attempts as (
    select
        att.id_tag,
        att.id_tag_status,
        att.charge_attempt_start_ts,
        att.incremental_ts
    from {{ ref('fact_charge_attempts') }} as att
    where att.incremental_ts > (select from_timestamp from incremental_date_range)
        and att.incremental_ts <= (select to_timestamp from incremental_date_range)
),

new_aggs as (
    select
        id_tag,
        min(charge_attempt_start_ts) as first_seen_ts,
        max(charge_attempt_start_ts) as last_seen_ts,
        {{ min_by('id_tag_status', 'charge_attempt_start_ts') }} as first_authorization_status,
        {{ max_by('id_tag_status', 'charge_attempt_start_ts') }} as latest_authorization_status,
        max(incremental_ts) as incremental_ts
    from attempts
    where id_tag is not null
    group by id_tag

    union all

    select
        '__UNKNOWN__' as id_tag,
        min(charge_attempt_start_ts) as first_seen_ts,
        max(charge_attempt_start_ts) as last_seen_ts,
        cast(null as {{ dbt.type_string() }}) as first_authorization_status,
        cast(null as {{ dbt.type_string() }}) as latest_authorization_status,
        max(incremental_ts) as incremental_ts
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
        n.incremental_ts as incremental_ts
    from new_aggs n
    left join {{ this }} b on n.id_tag = b.id_tag

{% else %}

    select * from new_aggs

{% endif %}
)

select
    id_tag,
    first_seen_ts,
    last_seen_ts,
    first_authorization_status,
    latest_authorization_status,
    incremental_ts
from final
