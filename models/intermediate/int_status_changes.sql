{{ 
    config(
        materialized="incremental", 
        unique_key=["charge_point_id", "connector_id", "ingested_ts"], 
        incremental_strategy="merge",
        cluster_by="ingested_ts"
    ) 
}}

{%- if is_incremental() -%}
    {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
{%- else -%}
    {%- set from_ts_caps = [
        "cast( '" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")",
        "(select min(ingested_timestamp) from " ~ ref("stg_ocpp_logs") ~ ")"
    ] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(from_timestamp_caps=from_ts_caps, buffer_minutes=30) }}
),

    ocpp_logs as (
        select
            charge_point_id,
            action,
            ingested_timestamp,
            message_type_id,
            payload,
            unique_id
        from {{ ref("stg_ocpp_logs") }}
        where ingested_timestamp > (select from_timestamp from incremental_date_range)
            and ingested_timestamp <= (select to_timestamp from incremental_date_range)
    ),

    incremental as (
        select
            max(ingested_timestamp) as incremental_ts
        from ocpp_logs
    ),

    -- Filter for StatusNotification events
    status_notification_events as (
        select
            ingested_timestamp,
            charge_point_id,
            unique_id,
            action,
            payload,
            {{ payload_extract_connector_id('action', 'payload') }} as connector_id,
            {{ payload_extract_status('action', 'payload') }} as status,
            {{ payload_extract_error_code('action', 'payload') }} as error_code,
            {{ payload_extract_timestamp('action', 'payload') }} as payload_ts
        from ocpp_logs
        where action = 'StatusNotification'
            and message_type_id = {{ var("message_type_ids").CALL }}
    ),

    -- Join status notifications with their confirmations and ports
    status_with_confirmation as (
        select
            -- Request details
            req.charge_point_id,
            req.connector_id,
            p.port_id,
            req.ingested_timestamp as ingested_ts,
            req.unique_id,
            req.status,
            req.error_code,
            req.payload,
            req.payload_ts,
            
            -- Confirmation details
            conf.ingested_timestamp as confirmation_ingested_ts
            
        from status_notification_events req
        left join {{ ref("stg_ports") }} p
            on req.charge_point_id = p.charge_point_id
            and req.connector_id = p.connector_id
        left join ocpp_logs conf
            on req.unique_id = conf.unique_id
            and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
            and conf.ingested_timestamp >= req.ingested_timestamp
            and conf.ingested_timestamp <= {{ dbt.dateadd("second", 15, "req.ingested_timestamp") }}
    ),

{% if is_incremental() %}
    
    -- Get previous statuses from the existing table to extend lag window
    statuses_buffer as (
        select
            charge_point_id,
            connector_id,
            port_id,
            ingested_ts,
            unique_id,
            status,
            error_code,
            payload,
            payload_ts,
            confirmation_ingested_ts,
            previous_status,
            previous_ingested_ts,
            previous_payload_ts
        from {{ this }}
        where (ingested_ts >= (select buffer_from_timestamp from incremental_date_range)
            and ingested_ts <= (select from_timestamp from incremental_date_range))
            and next_status is null
    ),

    statuses_with_buffer as (
        select 
            *,
            cast(null as {{ dbt.type_string() }}) as previous_status,
            cast(null as {{ dbt.type_timestamp() }}) as previous_ingested_ts,
            cast(null as {{ dbt.type_timestamp() }}) as previous_payload_ts
        from status_with_confirmation
        
        union all

        select
            charge_point_id,
            connector_id,
            port_id,
            ingested_ts,
            unique_id,
            status,
            error_code,
            payload,
            payload_ts,
            confirmation_ingested_ts,
            previous_status,
            previous_ingested_ts,
            previous_payload_ts
        from statuses_buffer
    ),

{% else %}
    statuses_with_buffer as (
        select 
            *,
            cast(null as {{ dbt.type_string() }}) as previous_status,
            cast(null as {{ dbt.type_timestamp() }}) as previous_ingested_ts,
            cast(null as {{ dbt.type_timestamp() }}) as previous_payload_ts
        from status_with_confirmation
    ),
{% endif %}

    -- Add previous status using window function on combined data
    -- Use coalesce to prefer existing previous_status from buffer over recalculated values
    status_with_lag as (
        select
            charge_point_id,
            connector_id,
            port_id,
            ingested_ts,
            unique_id,
            status,
            error_code,
            payload,
            payload_ts,
            confirmation_ingested_ts,

            coalesce(
                previous_status,
                lag(status) over (
                    partition by charge_point_id, connector_id order by ingested_ts
                )
            ) as previous_status,
            coalesce(
                previous_ingested_ts,
                lag(ingested_ts) over (
                    partition by charge_point_id, connector_id order by ingested_ts
                )
            ) as previous_ingested_ts,
            coalesce(
                previous_payload_ts,
                lag(payload_ts) over (
                    partition by charge_point_id, connector_id order by ingested_ts
                )
            ) as previous_payload_ts
        from statuses_with_buffer
    ),

    change_from_lag as (
        select *
        from status_with_lag
        where previous_status is null or previous_status <> status
    ),

    -- Add next status using window function (will be null for edge cases, updated in next run)
    status_with_lead as (
        select
            *,
            lead(status) over (
                partition by charge_point_id, connector_id order by ingested_ts
            ) as next_status,
            lead(ingested_ts) over (
                partition by charge_point_id, connector_id order by ingested_ts
            ) as next_ingested_ts,
            lead(payload_ts) over (
                partition by charge_point_id, connector_id order by ingested_ts
            ) as next_payload_ts
        from change_from_lag
    )

select
    charge_point_id,
    connector_id,
    port_id,
    ingested_ts,
    unique_id,
    status,
    error_code,
    payload,
    payload_ts,
    confirmation_ingested_ts,
    previous_status,
    previous_ingested_ts,
    previous_payload_ts,
    next_status,
    next_ingested_ts,
    next_payload_ts,
    (select incremental_ts from incremental) as incremental_ts
from status_with_lead
 
