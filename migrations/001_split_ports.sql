-- Migration: split RAW.SEED.ports into entity-grain tables
--
-- Before: one denormalised table at connector grain (all 7 columns)
-- After:  chargers   — one row per charge_point_id
--         ports      — one row per charge_point_id + port_id
--         connectors — one row per charge_point_id + port_id + connector_id
--
-- Run Phase 1 first, validate with dbt, then run Phase 2.
-- Phase 3 (drop legacy) is commented out — run manually after sign-off.

-- ── Phase 1: create new tables without touching the original ─────────────────

create table if not exists RAW.SEED.CHARGERS as
select distinct
    CHARGE_POINT_ID,
    LOCATION_ID,
    COMMISSIONED_TS,
    DECOMMISSIONED_TS
from RAW.SEED.PORTS;

create table if not exists RAW.SEED.PORTS_NEW as
select distinct
    CHARGE_POINT_ID,
    PORT_ID
from RAW.SEED.PORTS;

create table if not exists RAW.SEED.CONNECTORS as
select distinct
    CHARGE_POINT_ID,
    PORT_ID,
    CONNECTOR_ID,
    CONNECTOR_TYPE
from RAW.SEED.PORTS;

-- ── Grants: ensure TRANSFORMER can read the new tables ───────────────────────

grant select on table RAW.SEED.CHARGERS    to role TRANSFORMER;
grant select on table RAW.SEED.PORTS_NEW   to role TRANSFORMER;
grant select on table RAW.SEED.CONNECTORS  to role TRANSFORMER;

-- ── Corrections: fix connector types that differ from the source data ────────

update RAW.SEED.CONNECTORS
set CONNECTOR_TYPE = 'CHAdeMO'
where CHARGE_POINT_ID = 'CH-001' and PORT_ID = '2' and CONNECTOR_ID = '4';

-- ── Phase 2: swap ports (run after dbt build passes on the new tables) ───────

alter table RAW.SEED.PORTS     rename to RAW.SEED.PORTS_LEGACY;
alter table RAW.SEED.PORTS_NEW rename to RAW.SEED.PORTS;

-- ── Phase 3: cleanup (run after full validation) ─────────────────────────────

-- drop table RAW.SEED.PORTS_LEGACY;
