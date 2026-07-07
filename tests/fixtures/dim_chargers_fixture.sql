-- Fixture data for unit tests that mock dim_chargers.
-- Matches charger/location mapping used in dim_connectors_fixture.
select * from values
    ('CH-001', 'LOC-001'),
    ('CH-002', 'LOC-001'),
    ('CH-003', 'LOC-002')
as t (charger_id, location_id)
