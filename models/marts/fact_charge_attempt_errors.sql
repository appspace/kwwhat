{{
  config(
    materialized='incremental',
    unique_key=["charge_attempt_error_id"],
    incremental_strategy="merge",
    cluster_by="charge_attempt_start_ts"
  )
}}

{%- if is_incremental() -%}
    {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
{%- else -%}
    {%- set from_ts_caps = ["cast('" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")"] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(
        from_timestamp_caps=from_ts_caps,
        buffer_minutes=30,
        to_timestamp_caps=["(select max(incremental_ts) from " ~ ref("fact_charge_attempts") ~ ")"]
    ) }}
),

-- Charge attempts added or updated since the last run (buffered, in case
-- fact_charge_attempts re-merges a row - e.g. late-arriving transaction data -
-- so this table stays in sync with it).
attempts as (
    select
        charge_attempt_id,
        port_key,
        location_key,
        charger_id,
        connector_id,
        charge_attempt_start_ts,
        charge_attempt_stop_ts,
        incremental_ts
    from {{ ref('fact_charge_attempts') }}
    where incremental_ts > (select buffer_from_timestamp from incremental_date_range)
        and incremental_ts <= (select to_timestamp from incremental_date_range)
),

-- StatusNotification events within each attempt's window. Open/in-progress attempts
-- (charge_attempt_stop_ts is null) are bounded by this run's processing window rather
-- than an arbitrary future date, mirroring the error handling in fact_charge_attempts.
attempt_status_notifications as (
    select
        att.charge_attempt_id,
        att.port_key,
        att.location_key,
        att.charger_id,
        att.connector_id,
        att.charge_attempt_start_ts,
        att.incremental_ts,
        {{ payload_extract_error_code('logs.action', 'logs.payload') }} as error_code
    from attempts as att
    inner join {{ ref('int_ocpp_logs') }} as logs
        on att.charger_id = logs.charger_id
        and att.connector_id = logs.connector_id
        and logs.action = 'StatusNotification'
        and logs.message_type_id = {{ var("message_type_ids").CALL }}
        and logs.ingested_timestamp >= att.charge_attempt_start_ts
        and logs.ingested_timestamp <= coalesce(
            att.charge_attempt_stop_ts, (select to_timestamp from incremental_date_range)
        )
),

-- NoError is OCPP's "nothing wrong" sentinel, not a real error - excluded here.
attempt_errors as (
    select
        charge_attempt_id,
        port_key,
        location_key,
        charger_id,
        connector_id,
        charge_attempt_start_ts,
        incremental_ts,
        error_code
    from attempt_status_notifications
    where error_code is not null
        and error_code != 'NoError'
)

-- distinct collapses repeated occurrences of the same error_code within the same
-- attempt into a single row. No further aggregation needed: charge_attempt_start_ts,
-- incremental_ts, port_key, location_key, charger_id, and connector_id are all
-- functionally dependent on charge_attempt_id, so distinct on the full projection
-- is equivalent to distinct on (charge_attempt_id, error_code).
select distinct
    {{ dbt_utils.generate_surrogate_key([
        'charge_attempt_id', 'error_code'
    ]) }} as charge_attempt_error_id,
    charge_attempt_id,
    port_key,
    location_key,
    charger_id,
    connector_id,
    error_code,
    charge_attempt_start_ts,
    incremental_ts
from attempt_errors
