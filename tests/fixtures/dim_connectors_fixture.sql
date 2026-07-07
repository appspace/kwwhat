-- Fixture data for unit tests that mock dim_connectors.
-- Mimics the structure of connectors.csv: CH-001, CH-002, and CH-003 each have 2 ports, each with 2 connectors.
select * from values
    ('key_ch001_1_1', 'CH-001', '1', '1', 'CCS',  150, 'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp)),
    ('key_ch001_1_2', 'CH-001', '1', '2', 'NACS', 150, 'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp)),
    ('key_ch001_2_3', 'CH-001', '2', '3', 'CHAdeMO', 50,  'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp)),
    ('key_ch001_2_4', 'CH-001', '2', '4', 'CHAdeMO', 50,  'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp)),
    ('key_ch002_1_1', 'CH-002', '1', '1', 'CCS',  350, 'Available', 'NoError', cast('2025-09-15 10:30:00.000' as timestamp)),
    ('key_ch002_1_2', 'CH-002', '1', '2', 'NACS', 350, 'Available', 'NoError', cast('2025-09-15 10:30:00.000' as timestamp)),
    ('key_ch002_2_3', 'CH-002', '2', '3', 'CCS',  150, 'Available', 'NoError', cast('2025-09-15 10:30:00.000' as timestamp)),
    ('key_ch002_2_4', 'CH-002', '2', '4', 'NACS', 150, 'Available', 'NoError', cast('2025-09-15 10:30:00.000' as timestamp)),
    ('key_ch003_1_1', 'CH-003', '1', '1', 'CHAdeMO', 50,  'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp)),
    ('key_ch003_1_2', 'CH-003', '1', '2', 'CHAdeMO', 50,  'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp)),
    ('key_ch003_2_3', 'CH-003', '2', '3', 'CCS',  22,  'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp)),
    ('key_ch003_2_4', 'CH-003', '2', '4', 'NACS', 22,  'Available', 'NoError', cast('2025-10-01 08:00:00.000' as timestamp))
as t(connector_key, charge_point_id, port_id, connector_id, connector_type, max_power_kw, latest_status, latest_error_code, latest_status_ts)
