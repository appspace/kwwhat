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
                least(
                    {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }},
                    (select max(incremental_ts) from {{ ref("int_meter_values") }})
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
                (select max(incremental_ts) from {{ ref("int_meter_values") }})
            ) as to_timestamp
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

    meter_values as (
        select
            charge_point_id,
            transaction_id,
            ingested_ts,
            connector_id,
            measurand,
            unit,
            phase,
            {{ dbt.dateadd("minute", '-(minute(first_measurement_ts) % 15)', dbt.date_trunc("minute", 'first_measurement_ts')) }} as first_interval,
            {{ dbt.dateadd("minute", '-(minute(last_measurement_ts) % 15)', dbt.date_trunc("minute", 'last_measurement_ts')) }} as last_interval,
            first_measurement_ts,
            last_measurement_ts
        from {{ ref("int_meter_values") }}
    ),

    incremental as (
        select
            max(ingested_ts) as incremental_ts
        from ocpp_logs
    ),

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

    meter_value_records as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            -- Extract timestamp from the meter value object
            cast({{ fivetran_utils.json_extract(string="mv.value", string_path="timestamp") }} as {{ dbt.type_timestamp() }}) as meter_timestamp,
            -- Keep the full meter value object for now
            {{ fivetran_utils.json_extract(string="mv.value", string_path="sampledValue") }} as sample_values
        from meter_value_logs
        {{ json_array_unnest('meter_values') }} as mv
        where meter_values is not null
            and mv.value is not null
    ),

    sample_values as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            meter_timestamp,
            mv.value as sample_values
        from meter_value_records
        {{ json_array_unnest('sample_values') }} as mv
    ),

    measurements as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            meter_timestamp,
            {{ dbt.dateadd("minute", '-(minute(meter_timestamp) % 15)', dbt.date_trunc("minute", 'meter_timestamp')) }} as meter_15min_interval_start,
            {{ fivetran_utils.pivot_json_extract(string="sample_values", list_of_properties=["measurand", "value", "unit", "phase"]) }}
        from sample_values
    ),

    measurements_with_context as (
        select
            m.charge_point_id,
            m.connector_id,
            m.transaction_id,
            mv.ingested_ts,
            mv.first_interval,
            mv.last_interval,
            mv.first_measurement_ts,
            mv.last_measurement_ts,
            m.meter_timestamp,
            m.meter_15min_interval_start,
            m.measurand,
            m.unit,
            m.phase,
            m.value
        from measurements m
        left join meter_values mv on m.charge_point_id = mv.charge_point_id
            and m.connector_id = mv.connector_id
            and m.transaction_id = mv.transaction_id
            and m.measurand = mv.measurand
            and m.unit = mv.unit
            and ((m.phase is null and mv.phase is null) or m.phase = mv.phase)
            and m.meter_timestamp >= mv.first_measurement_ts
            and m.meter_timestamp <= mv.last_measurement_ts
    ),

    intervals_15min as (
            select
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
            -- Rebates reporting requires 15-minute interval data (e.g., 10:00, 10:15, 10:30).
            -- The first and last intervals correspond to when energy transfer starts and stops.
            case 
                when meter_15min_interval_start = first_interval then first_measurement_ts
                else meter_15min_interval_start 
            end as meter_15min_interval_start,
            case 
                when meter_15min_interval_start = last_interval then last_measurement_ts 
                else {{ dbt.dateadd("minute", 15, "meter_15min_interval_start") }}
            end as meter_15min_interval_stop,            
            measurand,
            unit,
            phase,
            value
        from measurements_with_context
        where value is not null and value != ''
    ),

    agg_15min as (
        select
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
            meter_15min_interval_start,
            meter_15min_interval_stop,
            measurand,
            unit,
            phase,
            
            -- interval avg value
            avg(cast(value as {{ dbt.type_float() }})) as avg_value,
            count(*) as _count
        from intervals_15min
        group by
            charge_point_id,
            transaction_id,
            connector_id,
            ingested_ts,
            meter_15min_interval_start,
            meter_15min_interval_stop,
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
            n.meter_15min_interval_start,
            n.meter_15min_interval_stop,
            case 
                when b.avg_value is null then n.avg_value
                else (n.avg_value*n._count + b.avg_value*b._count) / (n._count + b._count) 
            end as avg_value,
            case 
                when b._count is null then n._count
                else (n._count + b._count)
            end as _count
        from agg_15min n
        left join {{ this }} b
            on n.charge_point_id = b.charge_point_id
            and n.connector_id = b.connector_id
            and n.transaction_id = b.transaction_id
            and n.ingested_ts = b.ingested_ts
            and n.measurand = b.measurand
            and n.unit = b.unit
            and n.phase = b.phase
            and n.meter_15min_interval_start = b.meter_15min_interval_start

    {% else %}

        select
            *
        from agg_15min
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
        meter_15min_interval_start,
        meter_15min_interval_stop,
        avg_value,
        _count,
        (select incremental_ts from incremental) as incremental_ts
    from final
