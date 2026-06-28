{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        charge_point_id,
        port_id,
        location_id,
        count(connector_id) as connector_count
    from {{ ref('int_ports') }}
    group by
        charge_point_id,
        port_id,
        location_id
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charge_point_id',
        'ports.port_id'
        ]) }} as port_key,
    ports.charge_point_id,
    ports.location_id,
    ports.port_id,
    ports.connector_count
from ports
