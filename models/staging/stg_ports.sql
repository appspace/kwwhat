{{
  config(
    materialized='view'
  )
}}

with source as (
    select * from {{ source('raw', 'ports') }}
),

renamed as (
    select
        cast(charge_point_id as {{ dbt.type_string() }}) as charge_point_id,
        cast(location_id as {{ dbt.type_string() }}) as location_id,
        cast(port_id as {{ dbt.type_string() }}) as port_id,
        cast(connector_id as {{ dbt.type_string() }}) as connector_id,
        cast(connector_type as {{ dbt.type_string() }}) as connector_type,
        cast(commissioned_ts as {{ dbt.type_timestamp() }}) as commissioned_ts,
        cast(decommissioned_ts as {{ dbt.type_timestamp() }}) as decommissioned_ts
    from source
)

select * from renamed