{{
  config(
    materialized='table',
  )
}}

with attempts as (
    select
        case
            when att.id_tags is not null and {{ array_size('att.id_tags') }} > 0
                then cast({{ array_first('att.id_tags') }} as {{ dbt.type_string() }})
            else null
        end as id_tag,
        att.charge_attempt_start_ts,
        p.location_id
    from {{ ref('fact_charge_attempts') }} att
    inner join {{ ref('stg_ports') }} p
        on att.charge_point_id = p.charge_point_id
        and att.connector_id = p.connector_id
),

attempts_ranked as (
    select
        *,
        row_number() over (
            partition by id_tag is null, id_tag
            order by charge_attempt_start_ts
        ) as rn_first_in_group
    from attempts
),

known_drivers as (
    select
        {{ dbt_utils.generate_surrogate_key(['id_tag']) }} as driver_key,
        id_tag,
        true as is_known_driver,
        min(charge_attempt_start_ts) as first_seen_ts,
        max(charge_attempt_start_ts) as last_seen_ts,
        min(case when rn_first_in_group = 1 then location_id end) as first_seen_location_id
    from attempts_ranked
    where id_tag is not null
    group by id_tag
),

unknown_driver as (
    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as driver_key,
        'UNKNOWN' as id_tag,
        false as is_known_driver,
        coalesce(min(charge_attempt_start_ts), cast('1900-01-01' as {{ dbt.type_timestamp() }})) as
first_seen_ts,
        coalesce(max(charge_attempt_start_ts), cast('1900-01-01' as {{ dbt.type_timestamp() }})) as
last_seen_ts,
        min(case when rn_first_in_group = 1 then location_id end) as first_seen_location_id
    from attempts_ranked
    where id_tag is null
)

select
    driver_key,
    id_tag,
    is_known_driver,
    first_seen_ts,
    last_seen_ts,
    first_seen_location_id
from known_drivers
union all
select
    driver_key,
    id_tag,
    is_known_driver,
    first_seen_ts,
    last_seen_ts,
    first_seen_location_id
from unknown_driver