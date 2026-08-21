{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        charger_id,
        port_id,
        connector_count
    from {{ ref('int_ports') }}
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charger_id',
        'ports.port_id'
        ]) }} as port_key,
    ports.charger_id,
    ports.port_id,
    ports.connector_count
from ports
