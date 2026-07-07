{{
  config(
    materialized='view'
  )
}}

with source as (
    select * from {{ source('raw', 'connectors') }}
),

renamed as (
    select
        cast(charge_point_id as {{ dbt.type_string() }}) as charge_point_id,
        cast(port_id as {{ dbt.type_string() }}) as port_id,
        cast(connector_id as {{ dbt.type_string() }}) as connector_id,
        cast(connector_type as {{ dbt.type_string() }}) as connector_type
    from source
)

select
    charge_point_id,
    port_id,
    connector_id,
    connector_type
from renamed
