{{
  config(
    materialized='table'
  )
}}

with visit_chargers as (
    select
        v.visit_id,
        cast(charger.value as {{ dbt.type_string() }}) as charger_id
    from {{ ref('int_visits') }} as v
    {{ array_unnest('v.charger_ids') }} as charger
)

select
    visit_id,
    {{ dbt_utils.generate_surrogate_key(['charger_id']) }} as charger_key,
    charger_id
from visit_chargers
