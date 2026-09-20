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
        latest_vendor_id as latest_taxonomy,
        latest_info,
        latest_status_ts
    from {{ ref('int_connector_latest_status') }}
),

error_codes as (
    select
        error_code_key,
        taxonomy,
        fault_code
    from {{ ref('dim_error_codes') }}
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
    ocpp_error_codes.error_code_key as latest_error_code_key,
    latest_status.latest_vendor_error_code,
    vendor_error_codes.error_code_key as latest_vendor_error_code_key,
    latest_status.latest_taxonomy,
    latest_status.latest_info,
    latest_status.latest_status_ts
from connectors
left join latest_status
    on connectors.charger_id = latest_status.charger_id
    and connectors.connector_id = latest_status.connector_id
left join error_codes as ocpp_error_codes
    on ocpp_error_codes.taxonomy = 'ocpp1.6'
    and latest_status.latest_error_code = ocpp_error_codes.fault_code
left join error_codes as vendor_error_codes
    on latest_status.latest_taxonomy = vendor_error_codes.taxonomy
    and latest_status.latest_vendor_error_code = vendor_error_codes.fault_code
