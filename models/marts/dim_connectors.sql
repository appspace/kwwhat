{{
  config(
    materialized='table',
    description='Connector dimension. One row per Connector (charge_point_id + port_id + connector_id). Finest-grain hardware dimension. A Connector is an independently operated electrical outlet on a Port. A Port may have multiple Connectors (different socket types or tethered cables) to support different vehicle types (e.g. four-wheeled EVs and electric scooters). Sanity check: the Connector type answers "what vehicle types can charge here?".'
  )
}}

with connectors as (
    select
        charge_point_id,
        port_id,
        connector_id,
        connector_type
    from {{ ref('int_connectors') }}
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
        'connectors.charge_point_id',
        'connectors.port_id',
        'connectors.connector_id'
        ]) }} as connector_key,
    connectors.charge_point_id,
    connectors.port_id,
    connectors.connector_id,
    connectors.connector_type,
    latest_status.latest_status,
    latest_status.latest_error_code,
    latest_status.latest_status_ts
from connectors
left join latest_status
    on connectors.charge_point_id = latest_status.charge_point_id
    and connectors.connector_id = latest_status.connector_id
