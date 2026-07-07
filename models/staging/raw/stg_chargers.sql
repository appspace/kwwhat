{{
  config(
    materialized='view'
  )
}}

with source as (
    select * from {{ source('raw', 'chargers') }}
),

renamed as (
    select
        cast(charge_point_id as {{ dbt.type_string() }}) as charge_point_id,
        cast(location_id as {{ dbt.type_string() }}) as location_id,
        cast(commissioned_ts as {{ dbt.type_timestamp() }}) as commissioned_ts,
        cast(decommissioned_ts as {{ dbt.type_timestamp() }}) as decommissioned_ts
    from source
)

select distinct
    charge_point_id,
    location_id,
    commissioned_ts,
    decommissioned_ts
from renamed
