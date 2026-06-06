{{
  config(
    materialized='table',
    description='Port/connector dimension; full refresh from int_ports'
  )
}}

with ports as (
    select distinct
        charge_point_id, 
        port_id,
        location_id,
    from {{ ref('int_ports') }}
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charge_point_id', 
        'ports.port_id'
        ]) }} as port_key,
    ports.charge_point_id,
    ports.location_id,
    ports.port_id,
from ports
