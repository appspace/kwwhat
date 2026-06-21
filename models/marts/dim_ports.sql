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
        decommissioned_ts,
        count(connector_id) as connector_count,
    from {{ ref('int_ports') }}
    group by
        charge_point_id,
        port_id,
        location_id,
        decommissioned_ts
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charge_point_id', 
        'ports.port_id'
        ]) }} as port_key,
    ports.charge_point_id,
    ports.location_id,
    ports.port_id,
    ports.connector_count,
    ports.decommissioned_ts,
    ports.decommissioned_ts is null as is_active,
from ports
