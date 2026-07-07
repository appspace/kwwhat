{{
  config(
    materialized='table'
  )
}}

with ports as (
    select
        p.charge_point_id,
        p.port_id,
        p.max_power_kw,
        count(c.connector_id) as connector_count
    from {{ ref('int_ports') }} as p
    left join {{ ref('int_connectors') }} as c
        on p.charge_point_id = c.charge_point_id
        and p.port_id = c.port_id
    group by
        p.charge_point_id,
        p.port_id,
        p.max_power_kw
)

select
    {{ dbt_utils.generate_surrogate_key([
        'ports.charge_point_id',
        'ports.port_id'
        ]) }} as port_key,
    ports.charge_point_id,
    ports.port_id,
    ports.max_power_kw,
    ports.connector_count
from ports
