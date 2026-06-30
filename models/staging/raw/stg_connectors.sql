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
        cast(charge_point_id as {{ dbt.type_string() }}) as charger_id,
        cast(port_id as {{ dbt.type_string() }}) as port_id,
        cast(connector_id as {{ dbt.type_string() }}) as connector_id,
        cast(connector_type as {{ dbt.type_string() }}) as connector_type,
        cast(max_power_kw as numeric) as max_power_kw
    from source
)

select
    charger_id,
    port_id,
    connector_id,
    connector_type,
    max_power_kw
from renamed
