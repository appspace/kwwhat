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

    -- Example:
    -- [
    --     {
    --         sampledValue:
    --         [
    --             {measurand:Energy.Active.Import.Register,unit:Wh,value:2300270.0},
    --             {measurand:Voltage,phase:L1,unit:V,value:211.6},
    --             {measurand:Current.Import,phase:L1,unit:A,value:0.41},
    --             {measurand:Power.Offered,unit:W,value:1},
    --             {measurand:Power.Active.Import,unit:W,value:1}
    --         ],
    --         timestamp:2025-10-03T18:02:01.700Z
    --     }
    -- ]

    meter_value_messages as (
        select
            ingested_timestamp,
            charge_point_id,
            unique_id,
            payload,
            {{ payload_extract_connector_id('action', 'payload') }} as connector_id,
            {{ payload_extract_transaction_id('action', 'payload', 'null') }} as transaction_id,
            {{ payload_extract_meter_values('action', 'payload') }} as meter_values
        from ocpp_logs
        where action = 'MeterValues'
            and message_type_id = {{ var("message_type_ids").CALL }}
    ),

    meter_values as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            unique_id,
            ingested_timestamp,
            -- Extract timestamp from the meter value object
            cast({{ fivetran_utils.json_extract(string="mv.value", string_path="timestamp") }} as {{ dbt.type_timestamp() }}) as meter_timestamp,
            -- Keep the full meter value object for now
            {{ fivetran_utils.json_extract(string="mv.value", string_path="sampledValue") }} as sample_values
        from meter_value_messages
        {{ json_array_unnest('meter_values') }} as mv
        where meter_values is not null
            and mv.value is not null
    ),

    sample_values as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            unique_id,
            ingested_timestamp,
            meter_timestamp,
            mv.value as sample_values
        from meter_values
        {{ json_array_unnest('sample_values') }} as mv
    )

    select * from sample_values