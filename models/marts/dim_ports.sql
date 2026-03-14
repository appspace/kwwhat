{{
  config(
    materialized='table',
    description='Port/connector dimension; full refresh from stg_ports'
  )
}}

select
    charge_point_id,
    location_id,
    port_id,
    connector_id,
    connector_type,
    commissioned_ts,
    decommissioned_ts
from {{ ref('stg_ports') }}
