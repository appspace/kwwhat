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
        cast(charge_point_id as {{ dbt.type_string() }}) as charger_id,
        cast(port_id as {{ dbt.type_string() }}) as port_id
    from source
)

select distinct
    charger_id,
    port_id
from renamed
