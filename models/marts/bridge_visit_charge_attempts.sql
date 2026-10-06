{{
  config(
    materialized='table'
  )
}}

select
    v.visit_id,
    cast(charge_attempt.value as {{ dbt.type_string() }}) as charge_attempt_id
from {{ ref('int_visits') }} as v
{{ array_unnest('v.charge_attempt_ids') }} as charge_attempt
