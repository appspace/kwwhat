{{
  config(
    materialized='table'
  )
}}

with attempts as (
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
        att.charge_attempt_start_ts
    from {{ ref('fact_charge_attempts') }} att
),

known_drivers as (
    select
        {{ dbt_utils.generate_surrogate_key(['id_tag']) }} as driver_key,
        id_tag,
        true as is_known_driver,
        min(charge_attempt_start_ts) as first_seen_ts,
        max(charge_attempt_start_ts) as last_seen_ts,
        min_by(id_tag_status, charge_attempt_start_ts) as first_authorization_status,
        max_by(id_tag_status, charge_attempt_start_ts) as latest_authorization_status
    from attempts
    where id_tag is not null
    group by id_tag
),

unknown_driver as (
    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as driver_key,
        'UNKNOWN' as id_tag,
        false as is_known_driver,
        coalesce(min(charge_attempt_start_ts), cast('1900-01-01' as {{ dbt.type_timestamp() }})) as first_seen_ts,
        coalesce(max(charge_attempt_start_ts), cast('1900-01-01' as {{ dbt.type_timestamp() }})) as last_seen_ts,
        cast(null as {{ dbt.type_string() }}) as first_authorization_status,
        cast(null as {{ dbt.type_string() }}) as latest_authorization_status
    from attempts
    where id_tag is null
)

select
    driver_key,
    id_tag,
    is_known_driver,
    first_seen_ts,
    last_seen_ts,
    first_authorization_status,
    latest_authorization_status
from known_drivers
union all
select
    driver_key,
    id_tag,
    is_known_driver,
    first_seen_ts,
    last_seen_ts,
    first_authorization_status,
    latest_authorization_status
from unknown_driver
