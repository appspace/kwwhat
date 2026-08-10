-- Fixture data for unit tests that mock dim_chargers.
-- Matches charger/location mapping used in dim_connectors_fixture.
-- Written as `select ... union all select ...` rather than `select * from values (...) as t (...)`:
-- the VALUES-with-alias table constructor is Snowflake-only syntax, not supported by BigQuery.
select 'CH-001' as charger_id, 'LOC-001' as location_id
union all
select 'CH-002', 'LOC-001'
union all
select 'CH-003', 'LOC-002'
