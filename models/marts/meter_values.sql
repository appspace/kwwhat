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
            {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }} as to_timestamp
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
            {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }} as to_timestamp
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

    meter_value_events as (
        select
            ingested_timestamp,
            charge_point_id,
            unique_id,
            action,
            payload,
            {{ payload_extract_connector_id('action', 'payload') }} as connector_id,
            {{ payload_extract_status('action', 'payload') }} as status,
            {{ payload_extract_error_code('action', 'payload') }} as error_code
        from ocpp_logs
        where action = 'MeterValues'
            and message_type_id = {{ var("message_type_ids").CALL }}
    )

    select * from meter_value_events