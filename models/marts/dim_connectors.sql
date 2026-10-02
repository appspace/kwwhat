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
        connector_type,
        max_power_kw
    from {{ ref('int_connectors') }}
),

latest_status as (
    select
        charger_id,
        connector_id,
        latest_status,
        latest_error_code_name,
        latest_error_code,
        latest_taxonomy,
        latest_info,
        latest_status_ts
    from {{ ref('int_connector_latest_status') }}
),

error_codes as (
    select
        error_code_key,
        taxonomy,
        error_code,
        error_code_name
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
    connectors.max_power_kw,
    latest_status.latest_status,
    error_codes.error_code_key as latest_error_code_key,
    latest_status.latest_error_code_name,
    latest_status.latest_error_code,
    latest_status.latest_taxonomy,
    latest_status.latest_info,
    latest_status.latest_status_ts
from connectors
left join latest_status
    on connectors.charger_id = latest_status.charger_id
    and connectors.connector_id = latest_status.connector_id
-- Same resolution as fact_downtime_daily.latest_error_code_key - keep the two in sync.
-- Two mutually exclusive branches, so at most one dim_error_codes row matches:
-- vendor code reported -> (latest_taxonomy, latest_error_code), unique for vendor taxonomies;
-- no vendor code -> fall back to the OCPP 1.6 row for errorCode, unique on error_code_name there.
-- Name matching is limited to ocpp1.6: a vendor's own names can collide with OCPP's
-- (ChargeX CX002 is also 'GroundFailure') and would match the wrong code.
left join error_codes
    on (
        latest_status.latest_taxonomy = error_codes.taxonomy
        and latest_status.latest_error_code = error_codes.error_code
    )
    or (
        latest_status.latest_error_code is null
        and error_codes.taxonomy = 'ocpp1.6'
        and latest_status.latest_error_code_name = error_codes.error_code_name
    )
