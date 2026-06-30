{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        charger_id,
        port_id,
        connector_count,
        max_power_kw
    from {{ ref('int_ports') }}
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charger_id',
        'ports.port_id'
        ]) }} as port_key,
    ports.charger_id,
    ports.port_id,
    ports.max_power_kw,
    ports.connector_count
from ports
