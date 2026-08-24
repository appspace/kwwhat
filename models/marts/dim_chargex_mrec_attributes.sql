-- SCD Type 1 (static reference data, overwritten on each refresh)
-- Outrigger dimension owned by dim_error_codes: joins 1:1 on fault_code and reuses
-- dim_error_codes.error_code_key rather than recomputing its own surrogate key.
{{
  config(
    materialized='table'
  )
}}

with chargex_mrec_codes as (
    select
        fault_code,
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
),

chargex_error_codes as (
    select
        error_code_key,
        fault_code
    from {{ ref('dim_error_codes') }}
    where vendor = 'https://chargex.inl.gov'
)

select
    chargex_error_codes.error_code_key,
    chargex_mrec_codes.fault_code,
    chargex_mrec_codes.in_ocpp_1_6,
    chargex_mrec_codes.responsible_ev_user,
    chargex_mrec_codes.responsible_cso,
    chargex_mrec_codes.responsible_evse,
    chargex_mrec_codes.responsible_ev,
    chargex_mrec_codes.is_safety,
    chargex_mrec_codes.is_security,
    chargex_mrec_codes.is_maintenance,
    chargex_mrec_codes.is_financial,
    chargex_mrec_codes.is_authorization
from chargex_mrec_codes
inner join chargex_error_codes
    on chargex_mrec_codes.fault_code = chargex_error_codes.fault_code
