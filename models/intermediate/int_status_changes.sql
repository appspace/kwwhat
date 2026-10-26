{{
    config(
        materialized="incremental",
        unique_key=["charger_id", "connector_id", "ingested_ts"],
        incremental_strategy="merge",
        cluster_by="ingested_ts"
    )
}}

-- Incremental strategy: merge one row per charger_id + connector_id + ingested_ts.
-- Watermark: the shared warehouse checkpoint supplies the bounded processing window.
-- Reprocessing: every previously open status (next_status is null) is unioned with the new batch so lag/lead can
-- close the old status and establish the new connector state. updated_ts records the latest event that changed a row
-- (its own ingested_ts, then next_ingested_ts once closed); downstream models read changed rows by it.
-- Late arrivals: source rows at or before the checkpoint boundary require a backfill or full refresh.


with incremental_date_range as (
    {{ incremental_date_range() }}
),

    ocpp_logs as (
        select
            charger_id,
            action,
            ingested_timestamp,
            message_type_id,
            payload,
            unique_id,
            connector_id,
            port_id,
            location_id
        from {{ ref("int_ocpp_logs") }}
        where ingested_timestamp > (select from_timestamp from incremental_date_range)
            and ingested_timestamp <= (select to_timestamp from incremental_date_range)
    ),

    -- Filter for StatusNotification events
    status_notification_events as (
        select
            ingested_timestamp,
            charger_id,
            unique_id,
            action,
            payload,
            connector_id,
            port_id,
            location_id,
            {{ payload_extract_status('action', 'payload') }} as status,
            {{ payload_extract_error_code('action', 'payload') }} as error_code_name,
            {{ payload_extract_vendor_error_code('action', 'payload') }} as error_code,
            {{ payload_extract_vendor_id('action', 'payload') }} as taxonomy,
            {{ payload_extract_info('action', 'payload') }} as info,  -- noqa: RF04
            {{ payload_extract_timestamp('action', 'payload') }} as payload_ts
        from ocpp_logs
        where action = 'StatusNotification'
            and message_type_id = '{{ var("message_type_ids").CALL }}'
    ),

    -- Join status notifications with their confirmations
    status_with_confirmation as (
        select
            -- Request details
            req.charger_id,
            req.connector_id,
            req.port_id,
            req.location_id,
            req.ingested_timestamp as ingested_ts,
            req.unique_id,
            req.status,
            req.error_code_name,
            req.error_code,
            req.taxonomy,
            req.info,
            req.payload,
            req.payload_ts,

            -- Confirmation details
            conf.ingested_timestamp as confirmation_ingested_ts

        from status_notification_events as req
        left join ocpp_logs as conf
            on req.unique_id = conf.unique_id
            and conf.message_type_id = '{{ var("message_type_ids").CALLRESULT }}'
            and conf.ingested_timestamp >= req.ingested_timestamp
            and conf.ingested_timestamp <= {{ timestamp_add("second", 15, "req.ingested_timestamp") }}
    ),

{% if is_incremental() %}

    -- Each connector's open status (next_status not known yet), however old: the new batch's first status closes it.
    statuses_buffer as (
        select
            charger_id,
            connector_id,
            port_id,
            location_id,
            ingested_ts,
            unique_id,
            status,
            error_code_name,
            error_code,
            taxonomy,
            info,
            payload,
            payload_ts,
            confirmation_ingested_ts,
            previous_status,
            previous_ingested_ts,
            previous_payload_ts,
            updated_ts
        from {{ this }}
        where next_status is null
            and ingested_ts <= (select from_timestamp from incremental_date_range)
    ),

    statuses_with_buffer as (
        select
            *,
            cast(null as {{ dbt.type_string() }}) as previous_status,
            cast(null as {{ dbt.type_timestamp() }}) as previous_ingested_ts,
            cast(null as {{ dbt.type_timestamp() }}) as previous_payload_ts,
            cast(null as {{ dbt.type_timestamp() }}) as buffered_updated_ts
        from status_with_confirmation

        union all

        select
            charger_id,
            connector_id,
            port_id,
            location_id,
            ingested_ts,
            unique_id,
            status,
            error_code_name,
            error_code,
            taxonomy,
            info,
            payload,
            payload_ts,
            confirmation_ingested_ts,
            previous_status,
            previous_ingested_ts,
            previous_payload_ts,
            updated_ts as buffered_updated_ts
        from statuses_buffer
    ),

{% else %}
    statuses_with_buffer as (
        select
            *,
            cast(null as {{ dbt.type_string() }}) as previous_status,
            cast(null as {{ dbt.type_timestamp() }}) as previous_ingested_ts,
            cast(null as {{ dbt.type_timestamp() }}) as previous_payload_ts,
            cast(null as {{ dbt.type_timestamp() }}) as buffered_updated_ts
        from status_with_confirmation
    ),
{% endif %}

    -- Add previous status using window function on combined data
    -- Use coalesce to prefer existing previous_status from buffer over recalculated values
    status_with_lag as (
        select
            charger_id,
            connector_id,
            port_id,
            location_id,
            ingested_ts,
            unique_id,
            status,
            error_code_name,
            error_code,
            taxonomy,
            info,
            payload,
            payload_ts,
            confirmation_ingested_ts,
            buffered_updated_ts,

            coalesce(
                previous_status,
                lag(status) over (
                    partition by charger_id, connector_id order by ingested_ts
                )
            ) as previous_status,
            coalesce(
                previous_ingested_ts,
                lag(ingested_ts) over (
                    partition by charger_id, connector_id order by ingested_ts
                )
            ) as previous_ingested_ts,
            coalesce(
                previous_payload_ts,
                lag(payload_ts) over (
                    partition by charger_id, connector_id order by ingested_ts
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
                partition by charger_id, connector_id order by ingested_ts
            ) as next_status,
            lead(ingested_ts) over (
                partition by charger_id, connector_id order by ingested_ts
            ) as next_ingested_ts,
            lead(payload_ts) over (
                partition by charger_id, connector_id order by ingested_ts
            ) as next_payload_ts
        from change_from_lag
    )

select
    charger_id,
    connector_id,
    port_id,
    location_id,
    ingested_ts,
    unique_id,
    status,
    error_code_name,
    error_code,
    taxonomy,
    info,
    payload,
    payload_ts,
    confirmation_ingested_ts,
    previous_status,
    previous_ingested_ts,
    previous_payload_ts,
    next_status,
    next_ingested_ts,
    next_payload_ts,
    coalesce(
        greatest(buffered_updated_ts, coalesce(next_ingested_ts, ingested_ts)),
        coalesce(next_ingested_ts, ingested_ts)
    ) as updated_ts
from status_with_lead
-- A run with no new logs changes nothing: write nothing rather than rewrite the open statuses unchanged
where exists (select 1 from ocpp_logs)
