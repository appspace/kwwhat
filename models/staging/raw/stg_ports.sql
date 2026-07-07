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
        cast(port_id as {{ dbt.type_string() }}) as port_id,
        cast(max_power_kw as numeric) as max_power_kw
    from source
)

select distinct
    charge_point_id,
    port_id,
    max_power_kw
from renamed
