-- SCD Type 1 (static reference data, overwritten on each refresh)
{{
  config(
    materialized='table'
  )
}}

with chargex_error_codes as (
    select
        taxonomy,
        fault_code,
        error_code_name,
        description
    from {{ ref('chargex_mrec_codes') }}
),

ocpp_error_codes as (
    select
        'ocpp1.6' as taxonomy,
        value as fault_code,
        value as error_code_name,
        description
    from {{ ref('ocpp_1_6_error_codes') }}
),

-- Generic, multi-taxonomy reference: add one CTE per new source - vendor seed or protocol
-- standard, each carrying (or assigning) its own taxonomy - and union it in here.
all_error_codes as (
    select
        taxonomy,
        fault_code,
        error_code_name,
        description
    from chargex_error_codes

    union all

    select
        taxonomy,
        fault_code,
        error_code_name,
        description
    from ocpp_error_codes
)

select
    {{ dbt_utils.generate_surrogate_key(['taxonomy', 'fault_code']) }} as error_code_key,
    taxonomy,
    fault_code,
    error_code_name,
    description
from all_error_codes
