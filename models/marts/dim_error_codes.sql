-- SCD Type 1 (static reference data, overwritten on each refresh)
{{
  config(
    materialized='table'
  )
}}

with chargex_mrec_codes as (
    select
        fault_code,
        error_code_name,
        description,
        in_ocpp_1_6,
        responsible_ev_user,
        responsible_cso,
        responsible_evse,
        responsible_ev,
        is_safety,
        is_security,
        is_maintenance,
        is_financial,
        is_authorization
    from {{ ref('chargex_mrec_codes') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['fault_code']) }} as error_code_key,
    fault_code,
    error_code_name,
    description,
    in_ocpp_1_6,
    responsible_ev_user,
    responsible_cso,
    responsible_evse,
    responsible_ev,
    is_safety,
    is_security,
    is_maintenance,
    is_financial,
    is_authorization
from chargex_mrec_codes
