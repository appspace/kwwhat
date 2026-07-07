{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        charge_point_id,
        port_id,
        connector_count
    from {{ ref('int_ports') }}
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charge_point_id',
        'ports.port_id'
        ]) }} as port_key,
    ports.charge_point_id,
    ports.port_id,
    ports.connector_count
from ports
