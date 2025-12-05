{{
  config(
    materialized='incremental',
    unique_key=["charger_id", "date_id", "i"], 
    incremental_strategy="merge",
    cluster_by="date_id"
  )
}}

{% set charge_point_initiated_actions = ['Authorize', 'BootNotification', 'DataTransfer', 'DiagnosticStatusNotification', 'FirmwareStatusNotification', 'Heartbeat', 'MeterValues', 'StartTransaction', 'StatusNotification', 'StopTransaction'] %}
{% set interval_minutes = var("heartbeat_interval_seconds") / 60 %}
{% set intervals_per_day = (24 * 60 * 60) / var("heartbeat_interval_seconds") %}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }},
                (select max(ingested_timestamp) from {{ ref("stg_ocpp_logs") }})
            ) as to_timestamp
        from
            (
                select (select max(incremental_ts) from {{ this }}) as from_timestamp
            )
    ),

{% else %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }},
                (select max(ingested_timestamp) from {{ ref("stg_ocpp_logs") }})
            ) as to_timestamp
        from
            (
                select cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}) as from_timestamp
            )
    ),
{% endif %}

-- Generate all dates in the date range
dates as (
    select date_id
    from unnest(generate_date_array(
        cast((select buffer_from_timestamp from incremental_date_range) as date),
        cast((select to_timestamp from incremental_date_range) as date)
    )) as date_id
),

-- Generate all intervals for each date based on heartbeat_interval_seconds
-- intervals_per_day = 24 hours * 60 minutes * 60 seconds / heartbeat_interval_seconds
dates_context as (
    select
        ds.date_id,
        interval_num.value as i,
        {{ dbt.dateadd("minute", "(interval_num.value - 1) * " ~ (interval_minutes | int), "cast(ds.date_id as timestamp)") }} as interval_start_ts
    from dates ds
    cross join unnest(generate_array(1, {{ intervals_per_day | int }})) as interval_num
    where {{ dbt.dateadd("minute", "(interval_num.value - 1) * " ~ (interval_minutes | int), "cast(ds.date_id as timestamp)") }} >= (select buffer_from_timestamp from incremental_date_range)
        and {{ dbt.dateadd("minute", "(interval_num.value - 1) * " ~ (interval_minutes | int), "cast(ds.date_id as timestamp)") }} < (select to_timestamp from incremental_date_range)
),

-- Get charger commission information
charger_commission_info as (
    select
        charger_id,
        min(commissioned_ts) as commissioned_ts,
        max(decommissioned_ts) as decommissioned_ts
    from {{ ref("stg_ports") }}
    where commissioned_ts is not null
    group by charger_id
),

-- Create charger_context: for every charger, list every interval if was commissioned
charger_context as (
    select
        cci.charger_id,
        di.date_id,
        di.i,
        di.interval_start_ts
    from dates_context di
    cross join charger_commission_info cci
    where di.interval_start_ts >= cci.commissioned_ts
        and (cci.decommissioned_ts is null or di.interval_start_ts < cci.decommissioned_ts)
),

-- Get OCPP logs for the date range with interval buckets based on heartbeat_interval_seconds
-- Only include messages initiated by charge point (CALL messages)
ocpp_logs as (
    select distinct
        charge_point_id,
        cast(ingested_timestamp as date) as date_id,
        cast(div(extract(minute from ingested_timestamp) + extract(hour from ingested_timestamp) * 60, {{ interval_minutes | int }}) + 1 as int64) as i,
        ingested_timestamp
    from {{ ref("stg_ocpp_logs") }}
    where ingested_timestamp >= (select buffer_from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
        and message_type_id = {{ var("message_type_ids").CALL }}
        and action in ({{ "'" + "', '".join(charge_point_initiated_actions) + "'" }})
),

incremental as (
    select
        max(ingested_timestamp) as incremental_ts
    from ocpp_logs
),

-- Check for communication in each interval
communication_check as (
    select
        cc.charger_id,
        cc.date_id,
        cc.i,
        case 
            when log.charge_point_id is not null then 1
            else 0
        end as connected
    from charger_context cc
    left join ocpp_logs log
        on cc.charger_id = log.charge_point_id
        and cc.date_id = log.date_id
        and cc.i = log.i
)

select
    charger_id,
    date_id,
    i,
    connected,
    (select incremental_ts from incremental) as incremental_ts
from communication_check

