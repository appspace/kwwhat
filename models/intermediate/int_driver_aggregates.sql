{{
  config(
    materialized='incremental',
    unique_key='id_tag',
    incremental_strategy='merge'
  )
}}

{%- if is_incremental() -%}
    {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
{%- else -%}
    {%- set from_ts_caps = ["cast('" ~ var('start_processing_date') ~ "' as " ~ dbt.type_timestamp() ~ ")"] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(
        from_timestamp_caps=from_ts_caps,
        buffer_minutes=30
        ) }}
),

attempts as (
    select
        case
            when att.id_tags is not null and {{ array_size('att.id_tags') }} > 0
                then cast({{ array_first('att.id_tags') }} as {{ dbt.type_string() }})
            else null
        end as id_tag,
        case
            when att.id_tag_statuses is not null and {{ array_size('att.id_tag_statuses') }} > 0
                then cast({{ array_first('att.id_tag_statuses') }} as {{ dbt.type_string() }})
            else null
        end as id_tag_status,
        att.charge_attempt_start_ts,
        att.incremental_ts
    from {{ ref('fact_charge_attempts') }} att
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
{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}

    select
        n.id_tag,
        coalesce(b.first_seen_ts, n.first_seen_ts) as first_seen_ts,
        n.last_seen_ts as last_seen_ts,
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