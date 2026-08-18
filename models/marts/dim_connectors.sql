{{
  config(
    materialized='table'
  )
}}

with connectors as (
    select
        charger_id,
        port_id,
        connector_id,
        connector_type
    from {{ ref('int_connectors') }}
),

latest_status as (
    select
        charger_id,
        connector_id,
        latest_status,
        latest_error_code,
        latest_vendor_error_code,
        latest_status_ts
    from {{ ref('int_connector_latest_status') }}
)

select
    {{ dbt_utils.generate_surrogate_key([
        'connectors.charger_id',
        'connectors.port_id',
        'connectors.connector_id'
        ]) }} as connector_key,
    connectors.charger_id,
    connectors.port_id,
    connectors.connector_id,
    connectors.connector_type,
    latest_status.latest_status,
    latest_status.latest_error_code,
    latest_status.latest_vendor_error_code,
    latest_status.latest_status_ts
from connectors
left join latest_status
    on connectors.charger_id = latest_status.charger_id
    and connectors.connector_id = latest_status.connector_id
