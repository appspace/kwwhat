{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "from_ts"], 
    incremental_strategy="merge",
    cluster_by="from_ts"
  )
}}

{% set charge_point_initiated_actions = ['Authorize', 'BootNotification', 'DataTransfer', 'DiagnosticStatusNotification', 'FirmwareStatusNotification', 'Heartbeat', 'MeterValues', 'StartTransaction', 'StatusNotification', 'StopTransaction'] %}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
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

-- charger context: time window per charger that should have events within boundaries of this incremental run
charger_context as (
    select
        charge_point_id,
        greatest(
            min(commissioned_ts),
            (select from_timestamp from incremental_date_range)
        ) as monitoring_start_ts,
        least(
            coalesce(max(decommissioned_ts), (select to_timestamp from incremental_date_range)),
            (select to_timestamp from incremental_date_range)
        ) as monitoring_end_ts
    from {{ ref("stg_ports") }}
    where commissioned_ts is not null
        and commissioned_ts < (select to_timestamp from incremental_date_range)
        and (decommissioned_ts is null or decommissioned_ts > (select from_timestamp from incremental_date_range))
    group by charge_point_id
),

-- Charger messages: OCPP logs filtered for charge point initiated messages (CALL messages) joined with charger context
charger_messages as (
    select
        cc.charge_point_id,
        cc.monitoring_start_ts,
        cc.monitoring_end_ts,
        ol.ingested_timestamp
    from charger_context cc
    inner join {{ ref("stg_ocpp_logs") }} ol
        on cc.charge_point_id = ol.charge_point_id
        and ol.ingested_timestamp >= cc.monitoring_start_ts
        and ol.ingested_timestamp <= cc.monitoring_end_ts
        and ol.ingested_timestamp >= (select from_timestamp from incremental_date_range)
        and ol.ingested_timestamp <= (select to_timestamp from incremental_date_range)
        and ol.message_type_id = {{ var("message_type_ids").CALL }}
        and ol.action in ({{ "'" + "', '".join(charge_point_initiated_actions) + "'" }})
),

incremental as (
    select
        max(ingested_timestamp) as incremental_ts
    from charger_messages
),

message_gaps as (
    select
        charge_point_id,
        monitoring_start_ts,
        monitoring_end_ts,
        ingested_timestamp as current_ts,
        lag(ingested_timestamp) over (partition by charge_point_id order by ingested_timestamp) as prev_ts,
        lead(ingested_timestamp) over (partition by charge_point_id order by ingested_timestamp) as next_ts
    from charger_messages
),

outages_from_gaps as (
    -- Gap before first message (from monitoring_start to first message)
    select
        charge_point_id,
        monitoring_start_ts as from_ts,
        current_ts as to_ts
    from message_gaps
    where prev_ts is null and current_ts > monitoring_start_ts
    
    union all
    
    -- Gaps between consecutive messages
    select
        charge_point_id,
        prev_ts as from_ts,
        current_ts as to_ts
    from message_gaps
    where prev_ts is not null and prev_ts < current_ts
    
    union all
    
    -- Gap after last message (from last message to monitoring_end)
    select
        charge_point_id,
        current_ts as from_ts,
        monitoring_end_ts as to_ts
    from message_gaps
    where next_ts is null and current_ts < monitoring_end_ts
),

chargers_with_no_messages as (
    select
        cc.charge_point_id,
        cc.monitoring_start_ts as from_ts,
        cc.monitoring_end_ts as to_ts
    from charger_context cc
    where not exists (
        select 1
        from charger_messages cm
        where cm.charge_point_id = cc.charge_point_id
    )
),

new_outages as (
    select * from outages_from_gaps
    union all
    select * from chargers_with_no_messages
),

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
-- Read buffer of previous outages that might continue intocurrent period
previous_outages as (
    select
        charge_point_id,
        from_ts,
        to_ts
    from {{ this }}
    where to_ts = (select from_timestamp from incremental_date_range)
),

merged_outages as (
    select
        n.charge_point_id,
        least(coalesce(p.from_ts, n.from_ts), n.from_ts) as from_ts,
        greatest(coalesce(p.to_ts, n.to_ts), n.to_ts) as to_ts
    from new_outages n
    left join previous_outages p on n.charge_point_id = p.charge_point_id and p.to_ts = n.from_ts
),

all_outages as (
    select *,
        {{ dbt.datediff('from_ts', 'to_ts', 'seconds') }} as duration_seconds
    from merged_outages
)

{% else %}

all_outages as (
    select *,
        {{ dbt.datediff('from_ts', 'to_ts', 'seconds') }} as duration_seconds
    from new_outages
)

{% endif %}

select 
    charge_point_id,
    from_ts,
    to_ts,
    duration_seconds/60 as duration_minutes,
    (select incremental_ts from incremental) as incremental_ts
from all_outages
where duration_seconds > {{ var("heartbeat_interval_seconds") }}