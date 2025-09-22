{{
  config(
    materialized='incremental',
    unique_key='transaction_id',
    on_schema_change='sync_all_columns'
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
    where ingested_timestamp > (select from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
),

-- Filter for charge attempt actions first
transaction_events as (
    select *,
        {{ fivetran_utils.json_extract(string="payload", string_path="connectorId") }} as connector_id,
        {{ payload_extract_transaction_id('action', 'payload', 'conf_payload') }} as transaction_id as transaction_id
    from ocpp_logs
    where action in ({{ "'" + "', '".join(transaction_related_actions) + "'" }})
),

transaction_events_conf as (
    select req.*,
        conf.payload as conf_payload
    from transaction_events req
    left join ocpp_logs conf on req.unique_id = conf.unique_id
        and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
        and conf.ingested_timestamp >= req.ingested_timestamp
        and conf.ingested_timestamp <= {{ dbt.dateadd("second", 15, "req.ingested_timestamp") }}

),

-- Extract relevant details based on action type
transaction_details as (
    select
        -- Charge attempts details
        e.charge_point_id,
        e.connector_id,
        e.transaction_id,

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
        connector_id,
        
        -- Transaction timing details
        min(transaction_start_ts) as transaction_start_timestamp,
        max(transaction_stop_ts) as transaction_stop_timestamp,
        min(transaction_stop_reason) as transaction_stop_reason,
        
        --Authentication details
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag") }}) as id_tags,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag_status") }}) as id_tag_statuses,
        
        -- Energy transfer details
        min(meter_start) as meter_start,
        max(meter_stop) as meter_stop,
        
        -- Calculate energy transferred from meterStart and meterStop values
        cast(
            case 
                when min(meter_start) is not null and max(meter_stop) is not null
                then max(meter_stop) - min(meter_start)
                else null
            end as {{ dbt.type_numeric() }}
        ) as energy_transferred_wh,
        
        -- Error details
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="error_code") }}) as error_codes,
        
        -- Transaction details (for reference)
        min(transaction_start_timestamp) as transaction_start_timestamp,
        max(transaction_stop_timestamp) as transaction_stop_timestamp
        
    from transaction_details
    where transaction_id is not null
    group by 
        transaction_id,
        charge_point_id,
        connector_id
)

select *

from transactions
