{{ 
    config(
        materialized="incremental", 
        unique_key=["charge_point_id", "connector_id", "ingested_ts"], 
        incremental_strategy="merge",
        cluster_by="ingested_ts"
    ) 
}}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            {{ dbt.dateadd("month", 3, "from_timestamp") }} as to_timestamp
        from
            (
                select (select max(incremental_ts) from {{ this }}) as from_timestamp
            )
    ),

    -- Get previous statuses from the existing table to extend lag window
    statuses_buffer as (
        select
            charge_point_id,
            connector_id,
            ingested_ts,
            unique_id,
            status,
            error_code,
            payload,
            confirmation_ingested_ts,
            previous_status,
            previous_ingested_ts
        from {{ this }}
        where (ingested_ts >= (select buffer_from_timestamp from incremental_date_range)
            and ingested_ts <= (select from_timestamp from incremental_date_range))
            or next_status is null
    ),
{% else %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            {{ dbt.dateadd("month", 3, "from_timestamp") }} as to_timestamp
        from
            (
                select
                    greatest(
                        cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}),
                        (select min(ingested_timestamp) from {{ ref("stg_ocpp_logs") }})
                    ) as from_timestamp
            )
    ),
{% endif %}

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
            {{ fivetran_utils.json_extract(string="payload", string_path="connectorId")}} as connector_id,
            {{ fivetran_utils.json_extract(string="payload", string_path="status") }} as status,
            {{ fivetran_utils.json_extract(string="payload", string_path="errorCode") }} as error_code
        from ocpp_logs
        where action = 'StatusNotification'
            and message_type_id = {{ var("message_type_ids").CALL }}
    ),

    -- Join status notifications with their confirmations
    status_with_confirmation as (
        select
            -- Request details
            req.charge_point_id,
            req.connector_id,
            req.ingested_timestamp as ingested_ts,
            req.unique_id,
            req.status,
            req.error_code,
            req.payload,
            
            -- Confirmation details
            conf.ingested_timestamp as confirmation_ingested_ts
            
        from status_notification_events req
        left join ocpp_logs conf
            on req.unique_id = conf.unique_id
            and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
            and conf.ingested_timestamp >= req.ingested_timestamp
            and conf.ingested_timestamp <= {{ dbt.dateadd("second", 15, "req.ingested_timestamp") }}
    ),

    -- Combine current statuses with previous statuses for accurate lag calculation
    statuses_with_buffer as (
        select 
            *,
            cast(null as {{ dbt.type_string() }}) as previous_status,
            cast(null as {{ dbt.type_timestamp() }}) as previous_ingested_ts
        from status_with_confirmation
        
        {% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
        union all
        
        select * from statuses_buffer
        {% endif %}
    ),

    -- Add previous status using window function on combined data
    -- Use coalesce to prefer existing previous_status from buffer over recalculated values
    status_with_lag as (
        select
            charge_point_id,
            connector_id,
            ingested_ts,
            unique_id,
            status,
            error_code,
            payload,
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
            ) as previous_ingested_ts
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
            ) as next_ingested_ts
        from change_from_lag
    ),

    statuses as (
         select *,
            -- Calculate seconds to previous status
            case 
                when previous_ingested_ts is not null 
                then {{ dbt.datediff('previous_ingested_ts', 'ingested_ts', 'second') }}
                else null
            end as seconds_to_previous_status,
            -- Calculate seconds to next status
            case 
                when next_ingested_ts is not null 
                then {{ dbt.datediff('ingested_ts', 'next_ingested_ts', 'second') }}
                else null
            end as seconds_to_next_status
         from status_with_lead
    )

 select *,
    (select incremental_ts from incremental) as incremental_ts
 from statuses
 
