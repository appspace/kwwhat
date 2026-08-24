-- SCD Type 1 (static reference data, overwritten on each refresh)
{{
  config(
    materialized='table'
  )
}}

with chargex_error_codes as (
    select
        -- Matches the vendorId ChargeX's guide recommends reporting in StatusNotification
        -- alongside vendorErrorCode (see the ChargeX Implementation Guide), not the OEM name.
        'https://chargex.inl.gov' as vendor,
        fault_code,
        error_code_name,
        description
    from {{ ref('chargex_mrec_codes') }}
),

-- Generic, multi-vendor reference: add one CTE per new OEM (its own seed, its own vendor
-- literal) and union it in here.
all_error_codes as (
    select
        vendor,
        fault_code,
        error_code_name,
        description
    from chargex_error_codes
)

select
    {{ dbt_utils.generate_surrogate_key(['vendor', 'fault_code']) }} as error_code_key,
    vendor,
    fault_code,
    error_code_name,
    description
from all_error_codes
