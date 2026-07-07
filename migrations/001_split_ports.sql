-- Migration: split RAW.SEED.ports into entity-grain tables
--
-- Before: one denormalised table at connector grain (all 7 columns)
-- After:  chargers  — one row per charge_point_id
--         ports     — one row per charge_point_id + port_id
--         connectors — one row per charge_point_id + port_id + connector_id
--
-- Run Phase 1 first, validate with dbt, then run Phase 2.
-- Phase 3 (drop legacy) is commented out — run manually after sign-off.

-- ── Phase 1: create new tables without touching the original ─────────────────

CREATE TABLE IF NOT EXISTS RAW.SEED.chargers AS
SELECT DISTINCT
    charge_point_id,
    location_id,
    commissioned_ts,
    decommissioned_ts
FROM RAW.SEED.ports;

CREATE TABLE IF NOT EXISTS RAW.SEED.ports_new AS
SELECT DISTINCT
    charge_point_id,
    port_id
FROM RAW.SEED.ports;

CREATE TABLE IF NOT EXISTS RAW.SEED.connectors AS
SELECT DISTINCT
    charge_point_id,
    port_id,
    connector_id,
    connector_type
FROM RAW.SEED.ports;

-- ── Corrections: fix connector types that differ from the source data ────────

UPDATE RAW.SEED.connectors
SET connector_type = 'CHAdeMO'
WHERE charge_point_id = 'CH-001' AND port_id = '2' AND connector_id = '4';

-- ── Phase 2: swap ports (run after dbt build passes on the new tables) ───────

ALTER TABLE RAW.SEED.ports     RENAME TO RAW.SEED.ports_legacy;
ALTER TABLE RAW.SEED.ports_new RENAME TO RAW.SEED.ports;

-- ── Phase 3: cleanup (run after full validation) ─────────────────────────────

-- DROP TABLE RAW.SEED.ports_legacy;
