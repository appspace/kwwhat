{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "connector_id", "transaction_ingested_ts"], 
    incremental_strategy="merge",
    cluster_by="transaction_ingested_ts"
  )
}}

{% set transaction_related_actions = ['StartTransaction', 'StopTransaction', 'RemoteStartTransaction', 'RemoteStopTransaction', 'MeterValues'] %}

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
        ingested_timestamp as ingested_ts,
        message_type_id,
        payload,
        unique_id
    from {{ ref("stg_ocpp_logs") }}
    where ingested_timestamp > (select from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
),

incremental as (
    select
        max(ingested_ts) as incrememntal_ts
    from ocpp_logs
),

-- Filter for charge attempt actions first
transaction_events as (
    select *,
        {{ fivetran_utils.json_extract(string="payload", string_path="connectorId") }} as connector_id
    from ocpp_logs
    where action in ({{ "'" + "', '".join(transaction_related_actions) + "'" }})
),

transaction_events_conf as (
    select req.*,
        conf.payload as conf_payload
    from transaction_events req
    left join ocpp_logs conf on req.unique_id = conf.unique_id
        and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
        and conf.ingested_ts >= req.ingested_ts
        and conf.ingested_ts <= {{ dbt.dateadd("second", 15, "req.ingested_ts") }}

),

-- Extract relevant details based on action type
transaction_details as (
    select
        -- Charge attempts details
        e.charge_point_id,
        e.connector_id,
        e.ingested_ts,

        {{ payload_extract_transaction_id('action', 'payload', 'conf_payload') }} as transaction_id,
        -- Extract details based on action type using reusable macros
        {{ payload_extract_id_tag('action', 'payload', 'conf_payload') }} as id_tag,
        {{ payload_extract_id_tag_status('action', 'conf_payload') }} as id_tag_status,
        -- Transaction details
        {{ payload_extract_transaction_start_ts('action', 'payload') }} as transaction_start_ts,
        {{ payload_extract_transaction_stop_ts('action', 'payload') }} as transaction_stop_ts,
        {{ payload_extract_transaction_stop_reason('action', 'payload') }} as transaction_stop_reason,
        -- Meter details
        {{ payload_extract_meter_start('action', 'payload') }} as meter_start,
        {{ payload_extract_meter_stop('action', 'payload') }} as meter_stop,
        {{ payload_extract_meter_value('action', 'payload') }} as meter_value,
        -- Error details
        {{ payload_extract_error_code('action', 'payload') }} as error_code
    from transaction_events_conf e
),

-- Group by transaction_id and extract transaction-level details
transactions as (
    select
        transaction_id,
        charge_point_id,

        array_distinct({{ fivetran_utils.array_agg(field_to_agg="connector_id") }}) as connector_ids,
        
        -- Transaction timing details
        min(ingested_ts) as transaction_ingested_ts,
        min(transaction_start_ts) as transaction_start_ts,
        max(transaction_stop_ts) as transaction_stop_ts,
        min(transaction_stop_reason) as transaction_stop_reason,
        
        --Authentication details
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag") }}) as id_tags,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag_status") }}) as id_tag_statuses,
        
        -- Energy transfer details
        min(meter_start) as meter_start_kw,
        max(meter_stop) as meter_stop_kw,
        
        -- Error details
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="error_code") }}) as error_codes
        
    from transaction_details
    where transaction_id is not null
    group by 
        transaction_id,
        charge_point_id
)

select *,
        
        -- Calculate energy transferred from meterStart and meterStop values
        cast(
            case 
                when meter_start_kw is not null and meter_stop_kw is not null
                then (meter_stop_kw - meter_start_kw)/1000.0
                else null
            end as {{ dbt.type_numeric() }}
        ) as energy_transferred_kwh,
        case 
            when connector_ids is not null 
                then connector_ids[0]
            else null
        end as connector_id,

        -- Count aggregations for testing
        case 
            when connector_ids is not null 
                then {{ array_size('connector_ids') }}
            else 0
        end as _unique_connectors_count,

        (select incrememntal_ts from incremental) as incremental_ts

from transactions
