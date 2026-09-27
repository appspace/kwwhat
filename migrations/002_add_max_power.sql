-- Migration: add max_power_kw to port and connector tables
--
-- Idempotent: safe to re-run. Columns are only added if missing, and the merges
-- always converge each row to the values listed below.
--
-- number(10, 2) rather than plain number: Snowflake's default number(38, 0) would
-- truncate AC ratings such as 7.4 or 11.5 kW. Snowflake cannot change the scale of
-- an existing column, so if an earlier run already added max_power_kw as number(38, 0),
-- drop that column first and re-run this script.

alter table RAW.SEED.ports      add column if not exists max_power_kw number(10, 2);
alter table RAW.SEED.connectors add column if not exists max_power_kw number(10, 2);

-- Populate from hardware configuration data.
-- Replace with actual values from your CMMS or hardware registry.
merge into RAW.SEED.ports as target
using (
    select column1 as charge_point_id, column2 as port_id, column3 as max_power_kw
    from values
        ('CH-001', '1', 150),
        ('CH-001', '2', 150),
        ('CH-002', '1', 350),
        ('CH-002', '2', 150)
) as source
    on target.charge_point_id = source.charge_point_id
    and target.port_id = source.port_id
when matched and target.max_power_kw is distinct from source.max_power_kw then
    update set max_power_kw = source.max_power_kw;

merge into RAW.SEED.connectors as target
using (
    select column1 as charge_point_id, column2 as port_id, column3 as connector_id, column4 as max_power_kw
    from values
        ('CH-001', '1', '1', 150),
        ('CH-001', '1', '2', 150),
        ('CH-001', '2', '3', 150),
        ('CH-001', '2', '4', 50),
        ('CH-002', '1', '1', 350),
        ('CH-002', '1', '2', 350),
        ('CH-002', '2', '3', 150),
        ('CH-002', '2', '4', 150)
) as source
    on target.charge_point_id = source.charge_point_id
    and target.port_id = source.port_id
    and target.connector_id = source.connector_id
when matched and target.max_power_kw is distinct from source.max_power_kw then
    update set max_power_kw = source.max_power_kw;
