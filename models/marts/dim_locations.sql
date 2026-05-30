{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        location_id
    from {{ ref('stg_ports') }}
),

locations as (
    select distinct
        location_id
    from ports
)

select
    {{ dbt_utils.generate_surrogate_key(['location_id']) }} as location_key,
    location_id,
from locations