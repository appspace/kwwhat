{{
  config(
    materialized='incremental',
    unique_key=["charger_id", "connector_id", "ingested_ts"],
    incremental_strategy="merge",
    cluster_by="ingested_ts"
  )
}}

{% set transaction_related_actions = [
    'StartTransaction', 'StopTransaction',
    'RemoteStartTransaction', 'RemoteStopTransaction', 'MeterValues'
] %}

{% set relation_exists = adapter.get_relation(
    database=this.database, schema=this.schema, identifier=this.identifier
) %}

{% if is_incremental() and relation_exists %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd(
                var("incremental_window").unit,
                var("incremental_window").length,
                "from_timestamp"
            ) }} as to_timestamp
        from
            (
                select (select max(incremental_ts) from {{ this }}) as from_timestamp
            )
    ),

{% else %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd(
                var("incremental_window").unit,
                var("incremental_window").length,
                "from_timestamp"
            ) }} as to_timestamp
        from
            (
                select cast('{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}) as from_timestamp
            )
    ),
{% endif %}

ocpp_logs as (
    select
        charger_id,
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
        max(ingested_ts) as incremental_ts
    from ocpp_logs
),

-- Filter for charge attempt actions first
transaction_events as (
    select
        charger_id,
        action,
        ingested_ts,
        message_type_id,
        payload,
        unique_id,
        {{ payload_extract_connector_id('action', 'payload') }} as connector_id
    from ocpp_logs
    where action in ({{ "'" + "', '".join(transaction_related_actions) + "'" }})
),

transaction_events_conf as (
    select req.*,
        conf.payload as conf_payload
    from transaction_events as req
    left join ocpp_logs as conf on req.unique_id = conf.unique_id
        and conf.message_type_id = {{ var("message_type_ids").CALLRESULT }}
        and conf.ingested_ts >= req.ingested_ts
        and conf.ingested_ts <= {{ dbt.dateadd("second", 15, "req.ingested_ts") }}

),

-- Extract relevant details based on action type
transaction_details as (
    select
        -- Charge attempts details
        e.charger_id,
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
        {{ payload_extract_meter_value('action', 'payload') }} as meter_value
    from transaction_events_conf as e
),

-- Group by transaction_id and extract transaction-level details
transactions as (
    select
        transaction_id,
        charger_id,

        array_distinct({{ fivetran_utils.array_agg(field_to_agg="connector_id") }}) as connector_ids,

        -- Transaction timing details
        min(ingested_ts) as ingested_ts,
        min(transaction_start_ts) as transaction_start_ts,
        max(transaction_stop_ts) as transaction_stop_ts,
        max(ingested_ts) as last_ingested_ts,
        min(transaction_stop_reason) as transaction_stop_reason,

        --Authentication details
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag") }}) as id_tags,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="id_tag_status") }}) as id_tag_statuses,

        -- Energy transfer details
        min(meter_start) as meter_start_wh,
        max(meter_stop) as meter_stop_wh

    from transaction_details
    where transaction_id is not null
    group by
        transaction_id,
        charger_id
),

status_notifications as (
    select
        charger_id,
        ingested_ts,
        {{ payload_extract_connector_id('action', 'payload') }} as connector_id,
        {{ payload_extract_error_code('action', 'payload') }} as error_code
    from ocpp_logs
    where action = 'StatusNotification'
        and message_type_id = {{ var("message_type_ids").CALL }}
),

-- Join StatusNotification events that occurred during each transaction
transaction_status_notifications as (
    select
        t.transaction_id,
        t.charger_id,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="sn.error_code") }}) as error_codes
    from transactions as t
    left join status_notifications as sn
        on t.charger_id = sn.charger_id
        and sn.ingested_ts >= t.transaction_start_ts
        and sn.ingested_ts <= coalesce(t.transaction_stop_ts, t.last_ingested_ts)
        and {{ array_contains('t.connector_ids', 'sn.connector_id') }}
    group by
        t.transaction_id,
        t.charger_id
)

{% if is_incremental() and relation_exists %}
,

combined_transactions as (
    select
        n.charger_id,
        n.transaction_id,
        coalesce(b.ingested_ts, n.ingested_ts) as ingested_ts,
        coalesce(b.transaction_start_ts, n.transaction_start_ts) as transaction_start_ts,
        coalesce(b.transaction_stop_ts, n.transaction_stop_ts) as transaction_stop_ts,
        coalesce(b.last_ingested_ts, n.last_ingested_ts) as last_ingested_ts,
        coalesce(b.transaction_stop_reason, n.transaction_stop_reason) as transaction_stop_reason,
        coalesce(b.meter_start_wh, n.meter_start_wh) as meter_start_wh,
        coalesce(b.meter_stop_wh, n.meter_stop_wh) as meter_stop_wh,

        -- Merge arrays using array_concat
        array_distinct({{ array_concat('n.id_tags', 'b.id_tags') }}) as id_tags,
        array_distinct({{ array_concat('n.id_tag_statuses', 'b.id_tag_statuses') }}) as id_tag_statuses,
        array_distinct({{ array_concat('n.connector_ids', 'b.connector_ids') }}) as connector_ids

    from transactions as n
    left join {{ this }} as b
        on n.charger_id = b.charger_id
        and n.transaction_id = b.transaction_id
        and b.transaction_stop_ts is null
)
{% endif %}

,

transactions_final as (
    select
        t.*,
        tsn.error_codes,

        -- Calculate energy transferred from meterStart and meterStop values
        cast(
            case
                when t.meter_start_wh is not null and t.meter_stop_wh is not null
                then (t.meter_stop_wh - t.meter_start_wh) / 1000.0
            end as {{ dbt.type_numeric() }}
        ) as energy_transferred_kwh,
        case
            when t.connector_ids is not null and {{ array_size('t.connector_ids') }} > 0
                then {{ array_first('t.connector_ids') }}
        end as connector_id,

        -- Count aggregations for testing
        case
            when t.connector_ids is not null
                then {{ array_size('t.connector_ids') }}
            else 0
        end as _unique_connectors_count

    from
    {% if is_incremental() and relation_exists %}
        combined_transactions as t
    {% else %}
        transactions as t
    {% endif %}
    left join transaction_status_notifications as tsn
        on t.transaction_id = tsn.transaction_id
        and t.charger_id = tsn.charger_id
),

-- charger_id + connector_id -> port_id (int_connectors); charger_id -> location_id (int_chargers)
transactions_with_ids as (
    select
        transactions_final.*,
        connectors.port_id,
        chargers.location_id
    from transactions_final
    left join {{ ref('int_connectors') }} as connectors
        on transactions_final.charger_id = connectors.charger_id
        and transactions_final.connector_id = connectors.connector_id
    left join {{ ref('int_chargers') }} as chargers
        on transactions_final.charger_id = chargers.charger_id
)

select
    *,
    (select incremental_ts from incremental) as incremental_ts
from transactions_with_ids
