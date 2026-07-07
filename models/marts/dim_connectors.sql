{{
  config(
    materialized='table',
    description='Connector dimension; full refresh from int_connectors'
  )
}}

with connectors as (
    select
        charge_point_id,
        port_id,
        connector_id,
        connector_type,
        max_power_kw
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
    connectors.max_power_kw,
    latest_status.latest_status,
    latest_status.latest_error_code,
    latest_status.latest_status_ts
from connectors
left join latest_status
    on connectors.charge_point_id = latest_status.charge_point_id
    and connectors.connector_id = latest_status.connector_id
