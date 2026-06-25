{{
  config(
    materialized='table',
    description="Conformed location dimension. One row per distinct charging location. SCD Type 1."
  )
}}

with locations as (
    select distinct
        location_id,
    from {{ ref('int_ports') }}
)

select
    {{ dbt_utils.generate_surrogate_key(['location_id']) }} as location_key,
    location_id,
from locations