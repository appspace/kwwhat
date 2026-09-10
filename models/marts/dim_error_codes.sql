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

-- Generic, multi-vendor reference: add one CTE per new OEM (its own seed, already carrying
-- its own taxonomy column) and union it in here.
all_error_codes as (
    select
        taxonomy,
        fault_code,
        error_code_name,
        description
    from chargex_error_codes
)

select
    {{ dbt_utils.generate_surrogate_key(['taxonomy', 'fault_code']) }} as error_code_key,
    taxonomy,
    fault_code,
    error_code_name,
    description
from all_error_codes
