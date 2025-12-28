-- Fixture data for stg_ports unit test
select 
    'CH-001' as charge_point_id,
    '1' as connector_id,
    'LOC-001' as location_id,
    'PORT-001' as port_id,
    'CCS' as connector_type,
    cast('2024-01-01' as timestamp) as commissioned_ts,
    cast(null as timestamp) as decommissioned_ts

