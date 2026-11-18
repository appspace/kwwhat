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
        cast(port_id as {{ dbt.type_string() }}) as raw_port_id,
        cast(connector_id as {{ dbt.type_string() }}) as raw_connector_id,
        cast(connector_type as {{ dbt.type_string() }}) as connector_type,
        cast(max_power_kw as {{ dbt.type_numeric() }}) as max_power_kw
    from source
)

-- OCPP 1.6 numbers connectors per charger, not per port (port 2 of CH-002 has connectors 3 and 4),
-- so both ids are scoped by the charger: port_id 'CH-002-2', connector_id 'CH-002-3'
select
    charger_id,
    {{ network_scoped_id('charger_id', 'raw_port_id') }} as port_id,
    {{ network_scoped_id('charger_id', 'raw_connector_id') }} as connector_id,
    cast(raw_connector_id as {{ dbt.type_int() }}) as connector_number,
    connector_type,
    max_power_kw
from renamed
