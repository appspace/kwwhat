{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "connector_id", "charge_attempt_ingested_ts"], 
    incremental_strategy="merge",
    cluster_by="charge_attempt_ingested_ts"
  )
}}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd("month", 3, "from_timestamp") }},
                (select max(charge_attempt_ingested_ts) from {{ ref("int_charge_attempts") }}),
                (select max(transaction_ingested_ts) from {{ ref("int_transactions") }})
            ) as to_timestamp
        from
            (
                select (select max(charge_attempt_incremental_ts) from {{ this }}) as from_timestamp
            )
    ),
{% else %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd("month", 3, "from_timestamp") }},
                (select max(charge_attempt_ingested_ts) from {{ ref("int_charge_attempts") }}),
                (select max(transaction_ingested_ts) from {{ ref("int_transactions") }})
            ) as to_timestamp
        from
            (
                select
                    greatest(
                        cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}),
                        (select min(charge_attempt_ingested_ts) from {{ ref("int_charge_attempts") }}),
                        (select min(transaction_ingested_ts) from {{ ref("int_transactions") }})
                    ) as from_timestamp
            )
    ),
{% endif %}

charge_attempts as (
    select
        charge_point_id,
        connector_id,
        charge_attempt_unique_id,
        charge_attempt_ingested_ts,
        previous_status,
        status,
        next_status,
        id_tags,
        id_tag_statuses,
        transaction_id,
        error_codes,
        incremental_ts as charge_attempt_incremental_ts
    from {{ ref('int_charge_attempts') }}
    where charge_attempt_ingested_ts > (select from_timestamp from incremental_date_range)
        and charge_attempt_ingested_ts <= (select to_timestamp from incremental_date_range)
),

transactions as (
    select
        charge_point_id,
        connector_id,
        transaction_id,
        transaction_ingested_ts,
        transaction_start_ts,
        transaction_stop_ts,
        transaction_stop_reason,
        id_tags as transaction_id_tags,
        id_tag_statuses as transaction_id_tag_statuses,
        meter_start_kw,
        meter_stop_kw,
        energy_transferred_kwh,
        incremental_ts as transaction_incremental_ts
    from {{ ref('int_transactions') }}
    where transaction_ingested_ts > (select from_timestamp from incremental_date_range)
        and transaction_ingested_ts <= (select to_timestamp from incremental_date_range)
)

select
    -- Charge attempt identifiers
    ca.charge_point_id,
    ca.connector_id,
    ca.charge_attempt_unique_id,
    
    -- Charge attempt timing
    coalesce(ca.charge_attempt_ingested_ts, t.transaction_ingested_ts) as charge_attempt_ingested_ts,
    
    -- Charge attempt status flow
    ca.previous_status,
    ca.status,
    ca.next_status,
    
    -- Authentication details
    coalesce(ca.id_tags, t.transaction_id_tags) as id_tags,
    coalesce(ca.id_tag_statuses, t.transaction_id_tag_statuses) as id_tag_statuses,
    
    -- Transaction details
    coalesce(ca.transaction_id, t.transaction_id) as transaction_id,
    t.transaction_start_ts,
    t.transaction_stop_ts,
    t.transaction_ingested_ts,
    t.transaction_stop_reason,
    
    -- Transaction authentication details
    coalesce(ca.id_tags, t.transaction_id_tags) as transaction_id_tags,
    coalesce(ca.id_tag_statuses, t.transaction_id_tag_statuses) as transaction_id_tag_statuses,
    
    -- Energy transfer details
    t.meter_start_kw,
    t.meter_stop_kw,
    t.energy_transferred_kwh,
    
    -- Error details
    ca.error_codes as charge_attempt_error_codes,
    
    -- Processing metadata
    greatest(ca.charge_attempt_incremental_ts, t.transaction_incremental_ts) as incremental_ts    
    
from charge_attempts ca
full outer join transactions t
    on ca.charge_point_id = t.charge_point_id
    and ca.connector_id = t.connector_id
    and ca.transaction_id = t.transaction_id