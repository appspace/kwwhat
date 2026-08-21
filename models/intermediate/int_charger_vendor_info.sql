{{
    config(
        materialized="incremental",
        unique_key=["charger_id"],
        incremental_strategy="merge"
    )
}}

{%- set start_processing_date_cast = "cast( '" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")" -%}

{%- if is_incremental() -%}
    {#- BootNotification is rare enough that a window can legitimately find none at all,
       leaving this table with zero rows for a while - coalesce to start_processing_date so
       an as-yet-empty table doesn't resolve max(incremental_ts) to null and permanently
       zero out every future window's "> from_timestamp" filter. -#}
    {%- set from_ts_caps = [
        "coalesce((select max(incremental_ts) from " ~ this ~ "), " ~ start_processing_date_cast ~ ")"
    ] -%}
{%- else -%}
    {%- set from_ts_caps = [start_processing_date_cast] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(from_timestamp_caps=from_ts_caps, buffer_minutes=0) }}
),

ocpp_logs as (
    select
        charger_id,
        action,
        ingested_timestamp,
        message_type_id,
        payload
    from {{ ref("stg_ocpp_logs") }}
    cross join incremental_date_range
    where ingested_timestamp > incremental_date_range.from_timestamp
        and ingested_timestamp <= incremental_date_range.to_timestamp
),

-- Watermark for the next run's from_timestamp. Computed from all OCPP traffic in the
-- window, not just BootNotification, so it advances even when a window happens to carry
-- no BootNotification at all - BootNotification is rare (fired once per charger
-- commissioning/reboot), so gating the watermark on it risks the window never advancing.
incremental as (
    select max(ingested_timestamp) as incremental_ts
    from ocpp_logs
),

boot_notification_events as (
    select
        charger_id,
        ingested_timestamp,
        {{ payload_extract_charge_point_vendor('action', 'payload') }} as charge_point_vendor
    from ocpp_logs
    where action = 'BootNotification'
        and message_type_id = {{ var("message_type_ids").CALL }}
),

-- Keep only the latest known BootNotification per charger within this window
latest_per_charger as (
    select
        charger_id,
        charge_point_vendor,
        ingested_timestamp,
        row_number() over (
            partition by charger_id order by ingested_timestamp desc
        ) as _rn
    from boot_notification_events
)

select
    charger_id,
    charge_point_vendor,
    ingested_timestamp as latest_boot_notification_ts,
    (select incremental_ts from incremental) as incremental_ts
from latest_per_charger
where _rn = 1
