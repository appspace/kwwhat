{{
  config(
    materialized='table'
  )
}}

with locations as (
    select distinct
        location_id
    from {{ ref('int_chargers') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['location_id']) }} as location_key,
    location_id
from locations
