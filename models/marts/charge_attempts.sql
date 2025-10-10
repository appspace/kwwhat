{{
  config(
    materialized='incremental',
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

charge_attempts as (
    select
        charge_point_id,
        connector_id,
        unique_id as charge_attempt_unique_id,
        ingested_ts as charge_attempt_ingested_ts,
        previous_ingested_ts,
        next_ingested_ts,
        previous_status,
        status,
        next_status,
        id_tags,
        id_tag_statuses,
        transaction_id,
        error_codes,
        incremental_ts
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
                (select max(charge_attempt_ingested_ts) from charge_attempts), 
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
        coalesce(att.charge_point_id, t.charge_point_id) as charge_point_id,
        coalesce(att.connector_id, t.connector_id) as connector_id,
        coalesce(att.charge_attempt_ingested_ts, t.transaction_ingested_ts) as ingested_ts,
        
        -- Charge attempt details
        att.charge_attempt_ingested_ts,
        att.charge_attempt_unique_id,
        att.previous_status,
        att.status,
        att.next_status,
        array_distinct({{ array_concat('att.id_tags', 't.id_tags') }}) as id_tags,
        array_distinct({{ array_concat('att.id_tag_statuses', 't.id_tag_statuses') }}) as id_tag_statuses,

        -- Transaction details
        coalesce(att.transaction_id, t.transaction_id) as transaction_id,
        t.transaction_start_ts,
        t.transaction_stop_ts,
        t.transaction_ingested_ts,
        t.transaction_stop_reason,
        t.meter_start_wh,
        t.meter_stop_wh,
        t.energy_transferred_kwh,
        
        -- Error details - concatenate error codes from both sources
        array_distinct({{ array_concat('att.error_codes', 't.error_codes') }}) as error_codes
        
    from charge_attempts att
    full outer join transactions t
        on att.charge_point_id = t.charge_point_id
        and att.connector_id = t.connector_id
        and att.transaction_id = t.transaction_id
        and t.transaction_ingested_ts > {{ dbt.dateadd("second", -var("authorize_time_threshold_seconds"), 'coalesce(att.previous_ingested_ts, att.charge_attempt_ingested_ts)') }}
        and t.transaction_ingested_ts <= {{ dbt.dateadd("second", var("authorize_time_threshold_seconds"), 'coalesce(att.next_ingested_ts, att.charge_attempt_ingested_ts)') }}
        
)

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
   ,
   
    -- Read previously stored charge attempts within buffer window
    charge_attempts_buffer as (
        select
            charge_point_id,
            connector_id,
            ingested_ts,
            charge_attempt_unique_id,
            charge_attempt_ingested_ts,
            previous_status,
            status,
            next_status,
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
        where ingested_ts > (select buffer_from_timestamp from incremental_date_range)
            and ingested_ts <= (select from_timestamp from incremental_date_range)
    ),

    merged_attempts_and_transactions as (
        select
            n.charge_point_id,
            n.connector_id,
            coalesce(b.ingested_ts, n.ingested_ts) as ingested_ts,

            coalesce(n.charge_attempt_unique_id, b.charge_attempt_unique_id) as charge_attempt_unique_id,
            coalesce(n.charge_attempt_ingested_ts, b.charge_attempt_ingested_ts) as charge_attempt_ingested_ts,
            -- once set, ingested_ts should not be changed as it is a unique identifier (used for clustering/partitioning/merging)
            coalesce(n.previous_status, b.previous_status) as previous_status,
            coalesce(n.status, b.status) as status,
            coalesce(n.next_status, b.next_status) as next_status,
            coalesce(n.transaction_id, b.transaction_id) as transaction_id,
            coalesce(n.transaction_start_ts, b.transaction_start_ts) as transaction_start_ts,
            coalesce(n.transaction_stop_ts, b.transaction_stop_ts) as transaction_stop_ts,
            coalesce(n.transaction_ingested_ts, b.transaction_ingested_ts) as transaction_ingested_ts,
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
    (select incremental_ts from incremental) as incremental_ts
from 
{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    merged_attempts_and_transactions
{% else %}
    attempts_and_transactions
{% endif %}
