{{
  config(
    materialized='incremental',
    unique_key='charge_attempt_id',
    on_schema_change='sync_all_columns'
  )
}}

{% set charge_attempt_actions = ['Authorize', 'StartTransaction', 'StopTransaction', 'StatusNotification', 'RemoteStartTransaction', 'RemoteStopTransaction'] %}

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

-- Get status changes from the dedicated status changes model
status_changes_to_preparing as (
    select
        -- Request details
        charge_point_id,
        connector_id,
        unique_id,
        ingested_timestamp,
        status,
        previous_status,
        previous_ingested_timestamp,
        next_status,
        next_ingested_timestamp,
        error_code,
        -- payload,
        
        -- Confirmation details
        confirmation_ingested_timestamp
    from {{ ref('int_status_changes') }}
    where incremental_timestamp > (select buffer_from_timestamp from incremental_date_range)
        and incremental_timestamp <= (select to_timestamp from incremental_date_range)
        and status = 'Preparing'
),

ocpp_logs as (
    select *
    from {{ ref("stg_ocpp_logs") }}
    where ingested_timestamp > (select buffer_from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
),

-- Filter for charge attempt actions first
charge_attempt_events as (
    select *,
        {{ fivetran_utils.json_extract(string="payload", string_path="connectorId") }} as connector_id,
        {{ fivetran_utils.json_extract(string="payload", string_path="transactionId") }} as transaction_id
    from ocpp_logs
    where action in ({{ "'" + "', '".join(charge_attempt_actions) + "'" }})
),

charge_attempt_events_conf as (
    select req.*,
        conf.payload as conf_payload
    from charge_attempt_events req
    left join ocpp_logs conf on req.unique_id = conf.unique_id
        and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
        and conf.ingested_timestamp >= req.ingested_timestamp
        and conf.ingested_timestamp <= {{ dbt.dateadd("second", 15, "req.ingested_timestamp") }}

),

charge_attempt_events_chaining as (
    select
        -- Status change details
        att.charge_point_id,
        att.connector_id,
        att.unique_id as charge_attempt_unique_id,
        att.ingested_timestamp as charge_attempt_timestamp,
        att.previous_status,
        att.status,
        att.next_status,
        att.confirmation_ingested_timestamp,
        att.next_ingested_timestamp as first_status_transition_timestamp,
        
        -- Charge attempt event details
        e.ingested_timestamp,
        e.unique_id,
        e.action,
        e.payload,
        e.conf_payload
    from status_changes_to_preparing att
    left join charge_attempt_events_conf e
        on att.charge_point_id = e.charge_point_id
        and att.connector_id = e.connector_id
        and e.ingested_timestamp > att.previous_ingested_timestamp
        and e.ingested_timestamp <= att.next_ingested_timestamp
),

-- Extract relevant details based on action type
charge_attempt_details as (
    select
        -- Charge attempts details
        att.charge_point_id,
        att.connector_id,
        att.charge_attempt_unique_id,
        att.charge_attempt_timestamp,
        att.previous_status,
        att.status,
        att.next_status,
        att.confirmation_ingested_timestamp,
        att.first_status_transition_timestamp,
        
        -- Extract details based on action type using reusable macros
        {{ payload_extract_id_tag('action', 'payload', 'conf_payload') }} as id_tag,
        {{ payload_extract_id_tag_status('action', 'conf_payload') }} as id_tag_status,
        -- Transaction details
        {{ payload_extract_transaction_id('action', 'payload', 'conf_payload') }} as transaction_id,
        {{ payload_extract_transaction_start_ts('action', 'payload') }} as transaction_start_ts,
        {{ payload_extract_transaction_stop_ts('action', 'payload') }} as transaction_stop_ts,
        {{ payload_extract_transaction_stop_reason('action', 'payload') }} as transaction_stop_reason,
        -- Meter details
        {{ payload_extract_meter_start('action', 'payload') }} as meter_start,
        {{ payload_extract_meter_stop('action', 'payload') }} as meter_stop,
        -- Error details
        {{ payload_extract_error_code('action', 'payload') }} as error_code
    from charge_attempt_events_chaining att
),


-- Group by status change details and aggregate into arrays
charge_attempts as (
    select
        -- Status change details (grouping keys)
        charge_point_id,
        connector_id,
        charge_attempt_unique_id,
        charge_attempt_timestamp,
        previous_status,
        status,
        next_status,
        confirmation_ingested_timestamp,
        next_status_timestamp,
                
        -- Aggregate extracted details into arrays
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag") }}) as id_tags,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag_status") }}) as id_tag_statuses,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="transaction_id") }}) as transaction_ids,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="error_code") }}) as error_codes
                
    from charge_attempt_details
    group by 
        charge_point_id,
        connector_id,
        charge_attempt_unique_id,
        charge_attempt_timestamp,        
        previous_status,
        status,
        next_status,
        confirmation_ingested_timestamp,
        next_status_timestamp
)

select *,
    -- Count aggregations for testing
    case 
        when transaction_ids is not null 
        then {{ array_size('transaction_ids') }}
        else 0
    end as _unique_transaction_count

from charge_attempts