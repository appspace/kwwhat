-- Fixture data for stg_ports unit test
-- Mimics the structure of ports.csv: CH-001, CH-002, and CH-003 each have 2 ports, each with 2 connectors
select * from values
    ('CH-001', 'LOC-001', '1', '1', 'CCS', cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-001', 'LOC-001', '1', '2', 'NACS', cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-001', 'LOC-001', '2', '3', 'CCS', cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-001', 'LOC-001', '2', '4', 'NACS', cast('2025-10-01 08:00:00.000' as timestamp), cast('2025-10-15 07:55:00.100' as timestamp)),
    ('CH-002', 'LOC-001', '1', '1', 'CCS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-002', 'LOC-001', '1', '2', 'NACS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-002', 'LOC-001', '2', '3', 'CCS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-002', 'LOC-001', '2', '4', 'NACS', cast('2025-09-15 10:30:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '1', '1', 'CCS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '1', '2', 'NACS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '2', '3', 'CCS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp)),
    ('CH-003', 'LOC-002', '2', '4', 'NACS', cast('2025-10-01 08:00:00.000' as timestamp), cast(null as timestamp))
as t(charge_point_id, location_id, port_id, connector_id, connector_type, commissioned_ts, decommissioned_ts)

