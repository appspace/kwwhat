{{
  config(
    materialized='table',
    description='Connector dimension; full refresh from int_ports'
  )
}}

with ports as (
    select
        charge_point_id,
        location_id,
        port_id,
        connector_id,
        connector_type
    from {{ ref('int_ports') }}
),

latest_status as (
    select
        charge_point_id,
        connector_id,
        latest_status,
        latest_error_code,
        latest_status_ts
    from {{ ref('int_connector_latest_status') }}
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charge_point_id',
        'ports.port_id',
        'ports.connector_id'
        ]) }} as connector_key,
    ports.charge_point_id,
    ports.location_id,
    ports.port_id,
    ports.connector_id,
    ports.connector_type,
    latest_status.latest_status,
    latest_status.latest_error_code,
    latest_status.latest_status_ts
from ports
left join latest_status
    on ports.charge_point_id = latest_status.charge_point_id
    and ports.connector_id = latest_status.connector_id
