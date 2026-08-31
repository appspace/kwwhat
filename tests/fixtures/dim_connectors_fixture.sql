-- Fixture data for unit tests that mock dim_connectors.
-- Mimics the structure of ports.csv: CH-001, CH-002, and CH-003 each have 2 ports, each with 2 connectors
-- Written as `select ... union all select ...` rather than `select * from values (...) as t (...)`:
-- the VALUES-with-alias table constructor is Snowflake-only syntax, not supported by BigQuery.
select 'CH-001' as charger_id, 'LOC-001' as location_id, '1' as port_id, '1' as connector_id, 'CCS' as connector_type,
    cast('2025-10-01 08:00:00.000' as timestamp) as commissioned_ts, cast('2025-10-15 07:55:00.100' as timestamp) as decommissioned_ts
union all
select 'CH-001', 'LOC-001', '1', '2', 'NACS',
    cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)
union all
select 'CH-001', 'LOC-001', '2', '3', 'CCS',
    cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)
union all
select 'CH-001', 'LOC-001', '2', '4', 'NACS',
    cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)
union all
select 'CH-002', 'LOC-001', '1', '1', 'CCS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)
union all
select 'CH-002', 'LOC-001', '1', '2', 'NACS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)
union all
select 'CH-002', 'LOC-001', '2', '3', 'CCS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)
union all
select 'CH-002', 'LOC-001', '2', '4', 'NACS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)
union all
select 'CH-003', 'LOC-002', '1', '1', 'CCS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)
union all
select 'CH-003', 'LOC-002', '1', '2', 'NACS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)
union all
select 'CH-003', 'LOC-002', '2', '3', 'CCS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)
union all
select 'CH-003', 'LOC-002', '2', '4', 'NACS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)
