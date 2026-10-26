-- Migration: drop incremental_ts from the incremental models (ADR 0008)
--
-- The models no longer produce incremental_ts. Tables built before that still have the column, and an
-- incremental run into them fails with `invalid identifier 'INCREMENTAL_TS'`: on_schema_change is the
-- default `ignore`, so dbt merges using the existing table's column list.
--
-- Idempotent: safe to re-run. Written for analytics.dbt_prod; for another environment (e.g.
-- analytics.dbt_staging) replace the schema name.
--
-- Dropping the column is not enough for fact_charge_attempts, which gained updated_ts. That value is
-- derived during the merge and cannot be backfilled here, so after this script run:
--     dbt run --full-refresh --select fact_charge_attempts+
-- A full refresh of every incremental model also replaces rows built with the old window logic; if the
-- environment gets one anyway (the production job still runs full refreshes), this script is not needed.

alter table if exists analytics.dbt_prod.int_connector_latest_status drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.int_connector_preparing drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.int_driver_aggregates drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.int_faulted_outages drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.int_meter_values drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.int_offline_outages drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.int_status_changes drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.int_transactions drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.fact_charge_attempts drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.fact_downtime_daily drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.fact_interval_data drop column if exists incremental_ts;
alter table if exists analytics.dbt_prod.fact_visits drop column if exists incremental_ts;
