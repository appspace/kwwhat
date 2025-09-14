{{ 
    config(
        materialized="incremental", 
        unique_key=["charge_point_id", "connector_id", "ingested_timestamp"], 
        incremental_strategy="merge",
        cluster_by="ingested_timestamp"
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
                select (select max(incremental_timestamp) from {{ this }}) as from_timestamp
            )
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
        select *
        from {{ ref("stg_ocpp_logs") }}
        where ingested_timestamp > (select buffer_from_timestamp from incremental_date_range)
            and ingested_timestamp <= (select to_timestamp from incremental_date_range)
    ),

    incremental_ts as (
        select
            max(ingested_timestamp) as incremental_timestamp
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
            req.ingested_timestamp,
            req.unique_id,
            req.status,
            req.error_code,
            req.payload,
            
            -- Confirmation details
            conf.ingested_timestamp as confirmation_ingested_timestamp
            
        from status_notification_events req
        left join ocpp_logs conf
            on req.unique_id = conf.unique_id
            and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
            and conf.ingested_timestamp >= req.ingested_timestamp
            and conf.ingested_timestamp <= {{ dbt.dateadd("second", 15, "req.ingested_timestamp") }}
    ),

    -- Add previous status using window function
    status_with_lag as (
        select
            *,
            lag(status) over (
                partition by charge_point_id, connector_id order by ingested_timestamp
            ) as previous_status,
            lag(ingested_timestamp) over (
                partition by charge_point_id, connector_id order by ingested_timestamp
            ) as previous_ingested_timestamp
        from status_with_confirmation
    ),

    statuses as (
         select *,
            (select incremental_timestamp from incremental_ts) as incremental_timestamp
         from status_with_lag
    )

 select * 
 from statuses
 where previous_status is null or previous_status <> status
