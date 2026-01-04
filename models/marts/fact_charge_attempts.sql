{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "connector_id", "charge_attempt_start_ts"], 
    incremental_strategy="merge",
    cluster_by="charge_attempt_start_ts"
  )
}}

{% set VALID_STOP_REASONS = ['Local', 'Remote', 'EVDisconnected'] %}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd("month", 3, "from_timestamp") }},
                (select max(incremental_ts) from {{ ref("int_connector_preparing") }}),
                (select max(incremental_ts) from {{ ref("int_transactions") }})
            ) as to_timestamp
        from
            (
                select max(incremental_ts) as from_timestamp from {{ this }}
            )
    ),

{% else %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd("month", 3, "from_timestamp") }},
                (select max(incremental_ts) from {{ ref("int_connector_preparing") }}),
                (select max(incremental_ts) from {{ ref("int_transactions") }})
            ) as to_timestamp
        from
            (
                select cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}) as from_timestamp
            )
    ),
{% endif %}

preparing as (
    select
        charge_point_id,
        connector_id,
        unique_id as preparing_unique_id,
        ingested_ts as preparing_ingested_ts,
        previous_ingested_ts,
        next_ingested_ts,
        previous_status,
        status,
        next_status,
        payload_ts,
        next_payload_ts,
        id_tags,
        id_tag_statuses,
        transaction_id,
        error_codes,
        incremental_ts,

        -- Attempt start timestamp: use payload_ts if available, otherwise ingested_ts
        coalesce(payload_ts, ingested_ts) as preparing_start_ts,
        coalesce(next_payload_ts, next_ingested_ts) as preparing_stop_ts
    from {{ ref('int_connector_preparing') }}
    where ingested_ts > (select from_timestamp from incremental_date_range)
        and ingested_ts <= (select to_timestamp from incremental_date_range)
),

transactions as (
    select
        charge_point_id,
        connector_id,
        transaction_id,
        ingested_ts as transaction_ingested_ts,
        transaction_start_ts,
        transaction_stop_ts,
        transaction_stop_reason,
        id_tags,
        id_tag_statuses,
        meter_start_wh,
        meter_stop_wh,
        energy_transferred_kwh,
        error_codes,
        incremental_ts as transaction_incremental_ts
    from {{ ref('int_transactions') }}
    where ingested_ts > (select from_timestamp from incremental_date_range)
        and ingested_ts <= (select to_timestamp from incremental_date_range)
),

incremental as (
    select
        greatest(
            coalesce(
                (select max(preparing_ingested_ts) from preparing), 
                '1900-01-01'::timestamp
            ),
            coalesce(
                (select max(transaction_ingested_ts) from transactions), 
                '1900-01-01'::timestamp
            )
        ) as incremental_ts
),

attempts_and_transactions as (
    select
        -- Charge attempt identifiers
        coalesce(p.charge_point_id, t.charge_point_id) as charge_point_id,
        coalesce(p.connector_id, t.connector_id) as connector_id,

        -- Attempt start and stop timestamps depending on what we know
        coalesce(p.preparing_start_ts, t.transaction_start_ts) as charge_attempt_start_ts,
        coalesce(t.transaction_stop_ts, p.preparing_stop_ts) as charge_attempt_stop_ts,
        
        -- Charge attempt details
        p.preparing_ingested_ts,
        p.preparing_unique_id,
        p.previous_status,
        p.status,
        p.next_status,
        p.payload_ts as preparing_payload_ts,
        p.next_payload_ts as preparing_next_payload_ts,
        array_distinct({{ array_concat('p.id_tags', 't.id_tags') }}) as id_tags,
        array_distinct({{ array_concat('p.id_tag_statuses', 't.id_tag_statuses') }}) as id_tag_statuses,

        -- Transaction details
        coalesce(p.transaction_id, t.transaction_id) as transaction_id,
        t.transaction_start_ts,
        t.transaction_stop_ts,
        t.transaction_ingested_ts,
        t.transaction_stop_reason,
        t.meter_start_wh,
        t.meter_stop_wh,
        t.energy_transferred_kwh,
        
        -- Error details - concatenate error codes from both sources
        array_distinct({{ array_concat('p.error_codes', 't.error_codes') }}) as error_codes
        
    from preparing p
    full outer join transactions t
        on p.charge_point_id = t.charge_point_id
        and p.connector_id = t.connector_id
        and p.transaction_id = t.transaction_id
        and t.transaction_ingested_ts > {{ dbt.dateadd("second", -var("authorize_time_threshold_seconds"), 'coalesce(p.previous_ingested_ts, p.preparing_ingested_ts)') }}
        and t.transaction_ingested_ts <= {{ dbt.dateadd("second", var("authorize_time_threshold_seconds"), 'coalesce(p.next_ingested_ts, p.preparing_ingested_ts)') }}
        
)

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
   ,
   
    -- Read previously stored charge attempts within buffer window
    charge_attempts_buffer as (
        select
            charge_point_id,
            connector_id,
            charge_attempt_start_ts,
            charge_attempt_stop_ts,
            preparing_unique_id,
            preparing_ingested_ts,
            previous_status,
            status,
            next_status,
            preparing_payload_ts,
            preparing_next_payload_ts,
            id_tags,
            id_tag_statuses,
            transaction_id,
            transaction_start_ts,
            transaction_stop_ts,
            transaction_ingested_ts,
            transaction_stop_reason,
            meter_start_wh,
            meter_stop_wh,
            energy_transferred_kwh,
            error_codes,
            incremental_ts
        from {{ this }}
        where charge_attempt_start_ts > (select buffer_from_timestamp from incremental_date_range)
    ),

    merged_attempts_and_transactions as (
        select
            n.charge_point_id,
            n.connector_id,

            coalesce(b.charge_attempt_start_ts, n.charge_attempt_start_ts) as charge_attempt_start_ts,
            coalesce(n.charge_attempt_stop_ts, b.charge_attempt_stop_ts) as charge_attempt_stop_ts,

            coalesce(n.preparing_unique_id, b.preparing_unique_id) as preparing_unique_id,
            coalesce(n.preparing_ingested_ts, b.preparing_ingested_ts) as preparing_ingested_ts,
            coalesce(n.preparing_payload_ts, b.preparing_payload_ts) as preparing_payload_ts,
            coalesce(n.preparing_next_payload_ts, b.preparing_next_payload_ts) as preparing_next_payload_ts,
            coalesce(n.previous_status, b.previous_status) as previous_status,
            coalesce(n.status, b.status) as status,
            coalesce(n.next_status, b.next_status) as next_status,

            coalesce(n.transaction_id, b.transaction_id) as transaction_id,
            coalesce(n.transaction_ingested_ts, b.transaction_ingested_ts) as transaction_ingested_ts,
            coalesce(n.transaction_start_ts, b.transaction_start_ts) as transaction_start_ts,
            coalesce(n.transaction_stop_ts, b.transaction_stop_ts) as transaction_stop_ts,
            coalesce(n.transaction_stop_reason, b.transaction_stop_reason) as transaction_stop_reason,
            coalesce(n.meter_start_wh, b.meter_start_wh) as meter_start_wh,
            coalesce(n.meter_stop_wh, b.meter_stop_wh) as meter_stop_wh,
            coalesce(n.energy_transferred_kwh, b.energy_transferred_kwh) as energy_transferred_kwh,

            -- Merge arrays using array_concat
            array_distinct({{ array_concat('n.id_tags', 'b.id_tags') }}) as id_tags,
            array_distinct({{ array_concat('n.id_tag_statuses', 'b.id_tag_statuses') }}) as id_tag_statuses,
            array_distinct({{ array_concat('n.error_codes', 'b.error_codes') }}) as error_codes

        from attempts_and_transactions n
        left join charge_attempts_buffer b on n.charge_point_id = b.charge_point_id
            and n.connector_id = b.connector_id
            and n.transaction_id is not null and b.transaction_id is not null and n.transaction_id = b.transaction_id
    )
{% endif %}

select *,
    -- Generate a deterministic unique ID from the composite key
    {{ dbt_utils.generate_surrogate_key(['charge_point_id', 'connector_id', 'charge_attempt_start_ts']) }} as charge_attempt_id,
    case
        when transaction_id is not null
            and (next_status is null or next_status != 'Faulted')
            and transaction_stop_reason in ({{ "'" + "', '".join(VALID_STOP_REASONS) + "'" }})
            and energy_transferred_kwh is not null and energy_transferred_kwh > 0.1
        then true
        else false
    end as is_successful,
    (select incremental_ts from incremental) as incremental_ts
from 
{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    merged_attempts_and_transactions
{% else %}
    attempts_and_transactions
{% endif %}
