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
            -- TODO: least of +3 month, max ingested status changes, max ingested ocpp logs
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

-- Get status changes from the dedicated status changes model
status_changes_to_preparing as (
    select
        -- Request details
        charge_point_id,
        connector_id,
        unique_id,
        ingested_ts,
        status,
        previous_status,
        previous_ingested_ts,
        next_status,
        next_ingested_ts,
        error_code,
        -- payload,
        
        -- Confirmation details
        confirmation_ingested_ts
    from {{ ref('int_status_changes') }}
    where ingested_ts > (select buffer_from_timestamp from incremental_date_range)
        and ingested_ts <= (select to_timestamp from incremental_date_range)
        and status = 'Preparing'
),

ocpp_logs as (
    select
        charge_point_id,
        action,
        ingested_timestamp as ingested_ts,
        message_type_id,
        payload,
        unique_id
    from {{ ref("stg_ocpp_logs") }}
    where ingested_timestamp > (select buffer_from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
),

incremental as (
    select
        max(ingested_ts) as incremental_ts
    from ocpp_logs
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
        and conf.ingested_ts >= req.ingested_ts
        and conf.ingested_ts <= {{ dbt.dateadd("second", 15, "req.ingested_ts") }}

),

charge_attempt_events_chaining as (
    select
        -- Status change details
        att.charge_point_id,
        att.connector_id,
        att.unique_id as charge_attempt_unique_id,
        att.ingested_ts as charge_attempt_ingested_ts,
        att.previous_status,
        att.status,
        att.next_status,
        att.confirmation_ingested_ts,
        att.next_ingested_ts as first_status_transition_ts,
        
        -- Charge attempt event details
        e.ingested_ts,
        e.unique_id,
        e.action,
        e.payload,
        e.conf_payload
    from status_changes_to_preparing att
    left join charge_attempt_events_conf e
        on att.charge_point_id = e.charge_point_id
        and att.connector_id = e.connector_id
        and e.ingested_ts > att.previous_ingested_ts
        and e.ingested_ts <= att.next_ingested_ts
),

-- Extract relevant details based on action type
charge_attempt_details as (
    select
        -- Charge attempts details
        att.charge_point_id,
        att.connector_id,
        att.charge_attempt_unique_id,
        att.charge_attempt_ingested_ts,
        att.previous_status,
        att.status,
        att.next_status,
        att.confirmation_ingested_ts,
        att.first_status_transition_ts,
        
        -- Extract details based on action type using reusable macros
        {{ payload_extract_id_tag('action', 'payload', 'conf_payload') }} as id_tag,
        {{ payload_extract_id_tag_status('action', 'conf_payload') }} as id_tag_status,
        -- Transaction details
        {{ payload_extract_transaction_id('action', 'payload', 'conf_payload') }} as transaction_id,

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
        charge_attempt_ingested_ts,
        previous_status,
        status,
        next_status,
        confirmation_ingested_ts,
                
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
        charge_attempt_ingested_ts,        
        previous_status,
        status,
        next_status,
        confirmation_ingested_ts
)

select *,
    case 
        when transaction_ids is not null  and {{ array_size('transaction_ids') }} > 0
            then transaction_ids[0]
        else null
    end as transaction_id,
    (select incremental_ts from incremental) as incremental_ts,

    -- Count aggregations for testing
    case 
        when transaction_ids is not null 
            then {{ array_size('transaction_ids') }}
        else 0
    end as _unique_transaction_count

from charge_attempts