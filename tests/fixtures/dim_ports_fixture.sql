-- Fixture data for unit tests that mock dim_ports.
-- Matches charger/port mapping used in dim_connectors_fixture.
-- Written as `select ... union all select ...` rather than `select * from values (...) as t (...)`:
-- the VALUES-with-alias table constructor is Snowflake-only syntax, not supported by BigQuery.
select 'port-key-CH-001-1' as port_key, 'CH-001' as charger_id, '1' as port_id
union all
select 'port-key-CH-001-2', 'CH-001', '2'
union all
select 'port-key-CH-002-1', 'CH-002', '1'
union all
select 'port-key-CH-002-2', 'CH-002', '2'
union all
select 'port-key-CH-003-1', 'CH-003', '1'
union all
select 'port-key-CH-003-2', 'CH-003', '2'
