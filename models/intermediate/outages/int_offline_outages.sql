{{
  config(
    materialized='incremental',
    unique_key=["charger_id", "from_ts"],
    incremental_strategy="merge",
    cluster_by="from_ts"
  )
}}

-- Incremental strategy: merge one charger outage per charger_id + from_ts.
-- Watermark: the shared warehouse checkpoint supplies the bounded processing window.
-- Source messages are read through the claimed upper boundary. The boundary is inclusive so an outage cut off
-- by the prior run can be continued.
-- Reprocessing: a new boundary outage joins the target outage ending at the watermark and extends it via least/greatest.
-- Late arrivals before the boundary require a backfill or full refresh.


{% set charge_point_initiated_actions = [
    'Authorize', 'BootNotification', 'DataTransfer',
    'DiagnosticStatusNotification', 'FirmwareStatusNotification',
    'Heartbeat', 'MeterValues', 'StartTransaction',
    'StatusNotification', 'StopTransaction'
] %}

with incremental_date_range as (
    {{ incremental_date_range(
        to_timestamp_caps=["(select max(ingested_timestamp) from " ~ ref("stg_ocpp_logs") ~ ")"]
    ) }}
),

-- Charge point initiated messages (CALL messages) in this run's window
window_messages as (
    select
        charger_id,
        ingested_timestamp
    from {{ ref("stg_ocpp_logs") }}
    where ingested_timestamp >= (select from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
        and message_type_id = '{{ var("message_type_ids").CALL }}'
        and action in ({{ "'" + "', '".join(charge_point_initiated_actions) + "'" }})
),

-- Last message received in this window: the end of every ongoing outage. It is also the outage's to_ts, which
-- fact_downtime_daily reads changed outages by.
last_message as (
    select
        max(ingested_timestamp) as last_message_ts
    from window_messages
),

-- charger context: time window per charger that should have events within boundaries of this incremental run
charger_context as (
    select
        charger_id,
        greatest(
            commissioned_ts,
            (select from_timestamp from incremental_date_range)
        ) as monitoring_start_ts,
        least(
            coalesce(decommissioned_ts, (select last_message_ts from last_message)),
            (select last_message_ts from last_message)
        ) as monitoring_end_ts
    from {{ ref("int_chargers") }}
    where commissioned_ts is not null
        and commissioned_ts < (select last_message_ts from last_message)
        and (decommissioned_ts is null or decommissioned_ts > (select from_timestamp from incremental_date_range))
),

-- Charger messages: window messages joined with charger context
charger_messages as (
    select
        cc.charger_id,
        cc.monitoring_start_ts,
        cc.monitoring_end_ts,
        wm.ingested_timestamp
    from charger_context as cc
    inner join window_messages as wm
        on cc.charger_id = wm.charger_id
        and wm.ingested_timestamp >= cc.monitoring_start_ts
        and wm.ingested_timestamp <= cc.monitoring_end_ts
),

message_gaps as (
    select
        charger_id,
        monitoring_start_ts,
        monitoring_end_ts,
        ingested_timestamp as current_ts,
        lag(ingested_timestamp) over (partition by charger_id order by ingested_timestamp) as prev_ts,
        lead(ingested_timestamp) over (partition by charger_id order by ingested_timestamp) as next_ts
    from charger_messages
),

outages_from_gaps as (
    -- Gap before first message (from monitoring_start to first message)
    select
        charger_id,
        monitoring_start_ts as from_ts,
        current_ts as to_ts
    from message_gaps
    where prev_ts is null and current_ts > monitoring_start_ts

    union all

    -- Gaps between consecutive messages
    select
        charger_id,
        prev_ts as from_ts,
        current_ts as to_ts
    from message_gaps
    where prev_ts is not null and prev_ts < current_ts

    union all

    -- Gap after last message (from last message to monitoring_end)
    select
        charger_id,
        current_ts as from_ts,
        monitoring_end_ts as to_ts
    from message_gaps
    where next_ts is null and current_ts < monitoring_end_ts
),

chargers_with_no_messages as (
    select
        cc.charger_id,
        cc.monitoring_start_ts as from_ts,
        cc.monitoring_end_ts as to_ts
    from charger_context as cc
    where not exists (
        select 1
        from charger_messages as cm
        where cm.charger_id = cc.charger_id
    )
),

new_outages as (
    select charger_id, from_ts, to_ts from outages_from_gaps
    union all
    select charger_id, from_ts, to_ts from chargers_with_no_messages
),

{% if is_incremental() %}
-- Read buffer of previous outages that might continue into current period
previous_outages as (
    select
        charger_id,
        from_ts,
        to_ts
    from {{ this }}
    where to_ts = (select from_timestamp from incremental_date_range)
),

merged_outages as (
    select
        n.charger_id,
        least(coalesce(p.from_ts, n.from_ts), n.from_ts) as from_ts,
        greatest(coalesce(p.to_ts, n.to_ts), n.to_ts) as to_ts
    from new_outages n
    left join previous_outages p on n.charger_id = p.charger_id and p.to_ts = n.from_ts
),

all_outages as (
    select
        charger_id,
        from_ts,
        to_ts,
        {{ dbt.datediff('from_ts', 'to_ts', 'second') }} as duration_seconds
    from merged_outages
)

{% else %}

all_outages as (
    select
        charger_id,
        from_ts,
        to_ts,
        {{ dbt.datediff('from_ts', 'to_ts', 'second') }} as duration_seconds
    from new_outages
)

{% endif %}

select
    charger_id,
    from_ts,
    to_ts,
    duration_seconds / 60 as duration_minutes
from all_outages
where duration_seconds > {{ var("heartbeat_interval_seconds") }}
