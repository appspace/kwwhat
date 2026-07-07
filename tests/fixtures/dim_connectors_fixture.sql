-- Fixture data for unit tests that mock dim_connectors.
-- Mimics the structure of ports.csv: CH-001, CH-002, and CH-003 each have 2 ports, each with 2 connectors
select * from values
    ('CH-001', 'LOC-001', '1', '1', 'CCS', 150,
        cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-001', 'LOC-001', '1', '2', 'NACS', 150,
        cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-001', 'LOC-001', '2', '3', 'CCS', 150,
        cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-001', 'LOC-001', '2', '4', 'CHAdeMO', 50,
        cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-002', 'LOC-001', '1', '1', 'CCS', 350, cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-002', 'LOC-001', '1', '2', 'NACS', 350, cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-002', 'LOC-001', '2', '3', 'CCS', 150, cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-002', 'LOC-001', '2', '4', 'NACS', 150, cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '1', '1', 'CHAdeMO', 50, cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '1', '2', 'CHAdeMO', 50, cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '2', '3', 'CCS', 100, cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '2', '4', 'NACS', 100, cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp))
as t (charger_id, location_id, port_id, connector_id, connector_type, max_power_kw, commissioned_ts, decommissioned_ts)
