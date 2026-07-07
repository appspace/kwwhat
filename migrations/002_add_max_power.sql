-- Migration: add max_power_kw to port and connector tables

ALTER TABLE RAW.SEED.ports      ADD COLUMN max_power_kw NUMBER;
ALTER TABLE RAW.SEED.connectors ADD COLUMN max_power_kw NUMBER;

-- Populate from hardware configuration data.
-- Replace with actual values from your CMMS or hardware registry.
UPDATE RAW.SEED.ports SET max_power_kw = 150 WHERE charge_point_id = 'CH-001' AND port_id = '1';
UPDATE RAW.SEED.ports SET max_power_kw = 150 WHERE charge_point_id = 'CH-001' AND port_id = '2';
UPDATE RAW.SEED.ports SET max_power_kw = 350 WHERE charge_point_id = 'CH-002' AND port_id = '1';
UPDATE RAW.SEED.ports SET max_power_kw = 150 WHERE charge_point_id = 'CH-002' AND port_id = '2';

UPDATE RAW.SEED.connectors SET max_power_kw = 150 WHERE charge_point_id = 'CH-001' AND port_id = '1' AND connector_id = '1';
UPDATE RAW.SEED.connectors SET max_power_kw = 150 WHERE charge_point_id = 'CH-001' AND port_id = '1' AND connector_id = '2';
UPDATE RAW.SEED.connectors SET max_power_kw = 150 WHERE charge_point_id = 'CH-001' AND port_id = '2' AND connector_id = '3';
UPDATE RAW.SEED.connectors SET max_power_kw = 50  WHERE charge_point_id = 'CH-001' AND port_id = '2' AND connector_id = '4';
UPDATE RAW.SEED.connectors SET max_power_kw = 350 WHERE charge_point_id = 'CH-002' AND port_id = '1' AND connector_id = '1';
UPDATE RAW.SEED.connectors SET max_power_kw = 350 WHERE charge_point_id = 'CH-002' AND port_id = '1' AND connector_id = '2';
UPDATE RAW.SEED.connectors SET max_power_kw = 150 WHERE charge_point_id = 'CH-002' AND port_id = '2' AND connector_id = '3';
UPDATE RAW.SEED.connectors SET max_power_kw = 150 WHERE charge_point_id = 'CH-002' AND port_id = '2' AND connector_id = '4';
