-- Fixture data for unit tests that mock dim_ports.
-- Matches charger/port mapping used in dim_connectors_fixture.
select * from values
    ('port-key-CH-001-1', 'CH-001', '1'),
    ('port-key-CH-001-2', 'CH-001', '2'),
    ('port-key-CH-002-1', 'CH-002', '1'),
    ('port-key-CH-002-2', 'CH-002', '2'),
    ('port-key-CH-003-1', 'CH-003', '1'),
    ('port-key-CH-003-2', 'CH-003', '2')
as t (port_key, charger_id, port_id)
