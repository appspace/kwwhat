{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        charge_point_id,
        port_id,
        count(connector_id) as connector_count
    from {{ ref('int_connectors') }}
    group by
        charge_point_id,
        port_id
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charge_point_id',
        'ports.port_id'
        ]) }} as port_key,
    ports.charge_point_id,
    ports.port_id,
    ports.connector_count
from ports
