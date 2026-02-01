{{
  config(
    materialized='table',
    description='Port/connector dimension; full refresh from stg_ports'
  )
}}

select * from {{ ref('stg_ports') }}
