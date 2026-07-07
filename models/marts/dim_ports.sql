{{
  config(
    materialized='table',
    description='Port (EVSE) dimension. One row per Port (charge_point_id + port_id). A Port is an independently operated part of a Charger that can deliver energy to one EV at a time. Reliability and utilisation metrics (uptime, downtime, charge attempts) are tracked at Port grain. Sanity check: the number of Ports at a location answers "how many vehicles can charge simultaneously?".'
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
