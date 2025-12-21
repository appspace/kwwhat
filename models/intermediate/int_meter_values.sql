{{
    config(
        materialized="incremental",
        unique_key=["charge_point_id", "transaction_id", "ingested_ts", "connector_id", "measurand", "unit", "phase"],
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
            ingested_timestamp as ingested_ts,
            message_type_id,
            payload
        from {{ ref("stg_ocpp_logs") }}
        where ingested_timestamp > (select from_timestamp from incremental_date_range)
            and ingested_timestamp <= (select to_timestamp from incremental_date_range)
    ),

    transactions as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
            last_ingested_ts
        from {{ ref("int_transactions") }}
    ),

    incremental as (
        select
            max(ingested_ts) as incremental_ts
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

    meter_value_logs as (
        select
            ingested_ts,
            charge_point_id,
            payload,
            {{ payload_extract_connector_id('action', 'payload') }} as connector_id,
            {{ payload_extract_transaction_id('action', 'payload', 'null') }} as transaction_id,
            {{ payload_extract_meter_values('action', 'payload') }} as meter_values
        from ocpp_logs
        where action = 'MeterValues'
            and message_type_id = {{ var("message_type_ids").CALL }}
    ),

    meter_value_messages as (
        select
            l.charge_point_id,
            t.ingested_ts,
            l.connector_id,
            l.transaction_id,
            l.meter_values
        from meter_value_logs l
        left join transactions t on l.charge_point_id = t.charge_point_id
            and l.connector_id = t.connector_id
            and l.transaction_id = t.transaction_id
            and l.ingested_ts >= t.ingested_ts
            and l.ingested_ts <= t.last_ingested_ts
    ),

    meter_values as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
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
            ingested_ts,
            meter_timestamp,
            mv.value as sample_values
        from meter_values
        {{ json_array_unnest('sample_values') }} as mv
    ),

    measurements as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
            meter_timestamp,
            {{ dbt.dateadd("minute", '-(minute(meter_timestamp) % 15)', dbt.date_trunc("minute", 'meter_timestamp')) }} as meter_15min_interval_start,
            {{ fivetran_utils.pivot_json_extract(string="sample_values", list_of_properties=["measurand", "value", "unit", "phase"]) }}
        from sample_values
    ),

    agg_transaction as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
            measurand,
            unit,
            phase,
            -- Keep the first and last timestamps for context
            min(meter_timestamp) as first_measurement_ts,
            max(meter_timestamp) as last_measurement_ts,
            -- Aggregated values
            min(cast(value as {{ dbt.type_float() }})) as min_value,
            max(cast(value as {{ dbt.type_float() }})) as max_value,
            avg(cast(value as {{ dbt.type_float() }})) as avg_value,

            count(*) as _count
        from measurements
        where value is not null and value != ''
        group by
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
            measurand,
            unit,
            phase
    ),

    final as (
    {% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}

        select
            n.charge_point_id,
            n.transaction_id,
            n.ingested_ts,
            n.connector_id,
            n.measurand,
            n.unit,
            n.phase,
            case 
                when b.first_measurement_ts is null then n.first_measurement_ts
                else least(n.first_measurement_ts, b.first_measurement_ts) 
            end as first_measurement_ts,
            case 
                when b.last_measurement_ts is null then n.last_measurement_ts
                else greatest(n.last_measurement_ts, b.last_measurement_ts) 
            end as last_measurement_ts,
            case 
                when b.min_value is null then n.min_value
                else least(n.min_value, b.min_value) 
            end as min_value,
            case 
                when b.max_value is null then n.max_value
                else greatest(n.max_value, b.max_value) 
            end as max_value,
            case 
                when b.avg_value is null then n.avg_value
                else (n.avg_value*n._count + b.avg_value*b._count) / (n._count + b._count) 
            end as avg_value,
            case
                when b._count is null then n._count
                else n._count + b._count 
            end as _count
        from agg_transaction n
        left join {{ this }} b
            on n.charge_point_id = b.charge_point_id
            and n.connector_id = b.connector_id
            and n.transaction_id = b.transaction_id
            and n.ingested_ts = b.ingested_ts
            and n.measurand = b.measurand
            and n.unit = b.unit
            and n.phase = b.phase

    {% else %}

        select
            *
        from agg_transaction
    {% endif %}
    )

    select
        charge_point_id,
        transaction_id,
        ingested_ts,
        connector_id,
        measurand,
        unit,
        phase,
        first_measurement_ts,
        last_measurement_ts,
        min_value,
        max_value,
        avg_value,
        _count,
        (select incremental_ts from incremental) as incremental_ts
    from final