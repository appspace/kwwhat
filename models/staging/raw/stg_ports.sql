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
        cast(port_id as {{ dbt.type_string() }}) as raw_port_id,
        cast(max_power_kw as {{ dbt.type_numeric() }}) as max_power_kw
    from source
)

-- port_id is unique across the network: '<charger_id>-<port number within the charger>' ('CH-002-1')
select distinct
    charger_id,
    {{ network_scoped_id('charger_id', 'raw_port_id') }} as port_id,
    max_power_kw
from renamed
