{{
  config(
    materialized='table'
  )
}}

with all_driver_aggs as (
    select * from {{ ref('int_driver_aggregates') }}
),

known_drivers as (
    select
        {{ dbt_utils.generate_surrogate_key(['id_tag']) }} as driver_key,
        id_tag,
        true as is_known_driver,
        first_seen_ts,
        last_seen_ts,
        first_authorization_status,
        latest_authorization_status
    from all_driver_aggs
    where id_tag != '__UNKNOWN__'
),

unknown_driver as (
    select
        {{ dbt_utils.generate_surrogate_key(["'UNKNOWN'"]) }} as driver_key,
        'UNKNOWN' as id_tag,
        false as is_known_driver,
        coalesce(
            max(case when id_tag = '__UNKNOWN__' then first_seen_ts end),
            cast('1900-01-01' as {{ dbt.type_timestamp() }})
        ) as first_seen_ts,
        coalesce(
            max(case when id_tag = '__UNKNOWN__' then last_seen_ts end),
            cast('1900-01-01' as {{ dbt.type_timestamp() }})
        ) as last_seen_ts,
        cast(null as {{ dbt.type_string() }}) as first_authorization_status,
        cast(null as {{ dbt.type_string() }}) as latest_authorization_status
    from all_driver_aggs
),

final as (
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
)

select * from final
