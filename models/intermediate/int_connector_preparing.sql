{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "connector_id", "ingested_ts"], 
    incremental_strategy="merge",
    cluster_by="ingested_ts"
  )
}}

{% set charge_attempt_actions = ['Authorize', 'StartTransaction', 'StopTransaction', 'StatusNotification', 'RemoteStartTransaction', 'RemoteStopTransaction'] %}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }},
                (select max(incremental_ts) from {{ ref("int_status_changes") }}),
                (select max(ingested_timestamp) from {{ ref("stg_ocpp_logs") }})
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
                (select max(incremental_ts) from {{ ref("int_status_changes") }}),
                (select max(ingested_timestamp) from {{ ref("stg_ocpp_logs") }})
            ) as to_timestamp
        from
            (
                select cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}) as from_timestamp
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
        payload_ts,
        status,
        previous_status,
        previous_ingested_ts,
        previous_payload_ts,
        next_status,
        next_ingested_ts,
        next_payload_ts,
        error_code,
        incremental_ts,
        
        -- Confirmation details
        confirmation_ingested_ts
    from {{ ref('int_status_changes') }}
    -- equal as we want to grab statuses updated when last status changes ran (and later, so greater or equal)
    where ingested_ts >= (select buffer_from_timestamp from incremental_date_range)
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
    where ingested_timestamp >= (select buffer_from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
),

incremental as (
    select
        max(ingested_ts) as incremental_ts
    from status_changes_to_preparing
),


-- Filter for charge attempt actions first
charge_attempt_events as (
    select *
    from ocpp_logs
    where action in ({{ "'" + "', '".join(charge_attempt_actions) + "'" }})
        and message_type_id = {{ var("message_type_ids").CALL }}
),

charge_attempt_events_conf as (
    select req.*,
        conf.payload as conf_payload,
        {{ payload_extract_connector_id('req.action', 'req.payload') }} as connector_id,
        {{ payload_extract_transaction_id('req.action', 'req.payload', 'conf.payload') }} as transaction_id
    from charge_attempt_events req
    left join ocpp_logs conf on req.unique_id = conf.unique_id
        and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
        and conf.ingested_ts >= req.ingested_ts
        and conf.ingested_ts <= {{ dbt.dateadd("second", var("transaction_message_retry_interval"), "req.ingested_ts") }}

),

preparing_events_chaining as (
    select
        -- Status change details
        p.charge_point_id,
        p.connector_id,
        p.unique_id,
        p.ingested_ts,
        p.previous_status,
        p.status,
        p.next_status,
        p.confirmation_ingested_ts,
        p.previous_ingested_ts,
        p.next_ingested_ts,
        p.previous_payload_ts,
        p.next_payload_ts,
        p.payload_ts,
        
        -- Charge attempt event details
        e.action,
        e.payload,
        e.conf_payload
    from status_changes_to_preparing p
    left join charge_attempt_events_conf e on p.charge_point_id = e.charge_point_id
        and p.connector_id = e.connector_id
        and e.ingested_ts > coalesce(p.previous_ingested_ts, p.ingested_ts)
        and e.ingested_ts <= coalesce(p.next_ingested_ts, p.ingested_ts)

),

-- Extract relevant details based on action type
preparing_details as (
    select
        p.charge_point_id,
        p.connector_id,
        p.unique_id,
        p.ingested_ts,
        p.previous_status,
        p.status,
        p.next_status,
        p.confirmation_ingested_ts,
        p.previous_ingested_ts,
        p.next_ingested_ts,
        p.previous_payload_ts,
        p.next_payload_ts,
        p.payload_ts,
        
        {{ payload_extract_id_tag('action', 'payload', 'conf_payload') }} as id_tag,
        {{ payload_extract_id_tag_status('action', 'conf_payload') }} as id_tag_status,
        -- Transaction details
        {{ payload_extract_transaction_id('action', 'payload', 'conf_payload') }} as transaction_id,

        -- Error details
        {{ payload_extract_error_code('action', 'payload') }} as error_code
    from preparing_events_chaining p
),


-- Group by status change details and aggregate into arrays
preparing_agg as (
    select
        -- Status change details (grouping keys)
        charge_point_id,
        connector_id,
        unique_id,
        ingested_ts,
        previous_status,
        status,
        next_status,
        confirmation_ingested_ts,
        previous_ingested_ts,
        next_ingested_ts,
        previous_payload_ts,
        next_payload_ts,
        payload_ts,
        -- Aggregate extracted details into arrays
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag") }}) as id_tags,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag_status") }}) as id_tag_statuses,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="transaction_id") }}) as transaction_ids,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="error_code") }}) as error_codes
                
    from preparing_details
    group by 
        charge_point_id,
        connector_id,
        unique_id,
        ingested_ts,        
        payload_ts,
        previous_status,
        status,
        next_status,
        confirmation_ingested_ts,
        previous_ingested_ts,
        next_ingested_ts,
        previous_payload_ts,
        next_payload_ts
    )

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
,

combined_preparing as (
    select
        n.charge_point_id,
        n.connector_id,
        n.unique_id,
        n.ingested_ts,
        n.payload_ts,

        coalesce(n.previous_status, b.previous_status) as previous_status,
        coalesce(n.status, b.status) as status,
        coalesce(n.next_status, b.next_status) as next_status,
        coalesce(n.confirmation_ingested_ts, b.confirmation_ingested_ts) as confirmation_ingested_ts,
        coalesce(b.previous_ingested_ts, n.previous_ingested_ts) as previous_ingested_ts,
        coalesce(n.next_ingested_ts, b.next_ingested_ts) as next_ingested_ts,
        coalesce(b.previous_payload_ts, n.previous_payload_ts) as previous_payload_ts,
        coalesce(n.next_payload_ts, b.next_payload_ts) as next_payload_ts,

        array_distinct({{ array_concat('n.id_tags', 'b.id_tags') }}) as id_tags,

        array_distinct({{ array_concat('n.id_tag_statuses', 'b.id_tag_statuses') }}) as id_tag_statuses,

        array_distinct({{ array_concat('n.transaction_ids', 'b.transaction_ids') }}) as transaction_ids,

        array_distinct({{ array_concat('n.error_codes', 'b.error_codes') }}) as error_codes

    from preparing_agg n
    left join {{ this}} b
        on n.charge_point_id = b.charge_point_id
        and n.connector_id = b.connector_id
        and n.unique_id = b.unique_id
        and n.ingested_ts = b.ingested_ts
        and b.next_status is null
)
{% endif %}

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

from 
{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    combined_preparing
{% else %}
    preparing_agg
{% endif %}
