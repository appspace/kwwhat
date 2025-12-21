{{
  config(
    materialized='incremental',
    unique_key=["visit_id"], 
    incremental_strategy="merge",
    cluster_by="visit_start_ts"
  )
}}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd("minute", -30, "from_timestamp") }} as buffer_from_timestamp,
            least(
                {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }},
                (select max(incremental_ts) from {{ ref("fact_charge_attempts") }})
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
                {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }},
                (select max(incremental_ts) from {{ ref("fact_charge_attempts") }})
            ) as to_timestamp
        from
            (
                select cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}) as from_timestamp
            )
    ),
{% endif %}

-- Get charge attempts with location information
charge_attempts_with_location as (
    select
        ca.charge_point_id,
        ca.connector_id,
        ca.ingested_ts,
        ca.charge_attempt_unique_id,
        ca.transaction_id,
        ca.id_tags,
        ca.id_tag_statuses,
        ca.energy_transferred_kwh,
        p.location_id,
        -- Extract first idTag from array (or null if empty)
        case 
            when ca.id_tags is not null and {{ array_size('ca.id_tags') }} > 0
            then ca.id_tags[0]
            else null
        end as id_tag
    from {{ ref("fact_charge_attempts") }} ca
    inner join {{ ref("stg_ports") }} p
        on ca.charge_point_id = p.charge_point_id
        and ca.connector_id = p.connector_id
    where ca.ingested_ts > (select from_timestamp from incremental_date_range)
        and ca.ingested_ts <= (select to_timestamp from incremental_date_range)
),

incremental as (
    select
        max(ingested_ts) as incremental_ts
    from charge_attempts_with_location
),

-- For incremental runs, get previous visits that might need to be extended
{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
previous_visits as (
    select
        visit_id,
        location_id,
        id_tag,
        visit_start_ts,
        visit_end_ts,
        charge_attempt_count,
        charge_point_ids,
        connector_ids,
        transaction_ids,
        total_energy_transferred_kwh,
        visit_duration_minutes
    from {{ this }}
    where visit_end_ts >= (select buffer_from_timestamp from incremental_date_range)
        and visit_end_ts < (select to_timestamp from incremental_date_range)
),
{% endif %}

-- Identify visit groups using window functions
-- Strategy 1: Group by location_id and idTag (when idTag is not null) within 30 minutes
-- Strategy 2: Group by location_id and charge_point_id (when idTag is null) within 2 minutes
visit_candidates as (
    select
        cal.charge_point_id,
        cal.connector_id,
        cal.ingested_ts,
        cal.charge_attempt_unique_id,
        cal.transaction_id,
        cal.location_id,
        cal.id_tag,
        cal.id_tag_statuses,
        cal.energy_transferred_kwh,
        -- Determine grouping key: use idTag if available, otherwise use charge_point_id
        case 
            when cal.id_tag is not null then cal.id_tag
            else cal.charge_point_id
        end as grouping_key,
        -- Determine time window: 30 minutes for idTag, 2 minutes for charge_point_id
        case 
            when cal.id_tag is not null then 30
            else 2
        end as time_window_minutes,
        -- Find the previous attempt in the same group
        lag(ingested_ts) over (
            partition by cal.location_id, 
                case 
                    when cal.id_tag is not null then cal.id_tag
                    else cal.charge_point_id
                end
            order by cal.ingested_ts
        ) as prev_attempt_ts,
        -- Find the next attempt in the same group
        lead(ingested_ts) over (
            partition by cal.location_id,
                case 
                    when cal.id_tag is not null then cal.id_tag
                    else cal.charge_point_id
                end
            order by cal.ingested_ts
        ) as next_attempt_ts
    from charge_attempts_with_location cal
),

-- Identify visit boundaries: start a new visit when gap exceeds time window
visit_boundaries as (
    select
        *,
        case
            -- Start of visit: no previous attempt OR gap exceeds time window
            when prev_attempt_ts is null 
                or {{ dbt.datediff('prev_attempt_ts', 'ingested_ts', 'minute') }} > time_window_minutes
            then 1
            else 0
        end as is_visit_start,
        case
            -- End of visit: no next attempt OR gap exceeds time window
            when next_attempt_ts is null
                or {{ dbt.datediff('ingested_ts', 'next_attempt_ts', 'minute') }} > time_window_minutes
            then 1
            else 0
        end as is_visit_end
    from visit_candidates
),

-- Assign visit IDs using cumulative sum of visit starts
visits_with_ids as (
    select
        *,
        sum(is_visit_start) over (
            partition by location_id, grouping_key
            order by ingested_ts
            rows unbounded preceding
        ) as visit_number,
        -- Create visit_id: location_id + grouping_key + visit_number
        location_id || '_' || grouping_key || '_' || 
        cast(sum(is_visit_start) over (
            partition by location_id, grouping_key
            order by ingested_ts
            rows unbounded preceding
        ) as {{ dbt.type_string() }}) as visit_id
    from visit_boundaries
),

-- Aggregate visits
visits_aggregated as (
    select
        visit_id,
        location_id,
        id_tag,
        min(ingested_ts) as visit_start_ts,
        max(ingested_ts) as visit_end_ts,
        count(*) as charge_attempt_count,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="charge_point_id") }}) as charge_point_ids,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="connector_id") }}) as connector_ids,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="transaction_id") }}) as transaction_ids,
        sum(coalesce(energy_transferred_kwh, 0)) as total_energy_transferred_kwh,
        {{ dbt.datediff('min(ingested_ts)', 'max(ingested_ts)', 'minute') }} as visit_duration_minutes
    from visits_with_ids
    group by visit_id, location_id, id_tag
)

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
-- Merge with previous visits that might need extension
-- If a new visit starts within the time window of a previous visit's end, merge them
-- For idTag-based visits: match by location_id and idTag
-- For charge_point_id-based visits: match by location_id and check if charge_point_id is in previous visit's charge_point_ids array
visits_to_merge as (
    select
        nv.visit_id as new_visit_id,
        pv.visit_id as previous_visit_id,
        nv.location_id,
        nv.id_tag,
        nv.visit_start_ts,
        pv.visit_end_ts,
        case when nv.id_tag is not null then 30 else 2 end as time_window_minutes
    from visits_aggregated nv
    inner join previous_visits pv
        on pv.location_id = nv.location_id
        and (
            -- Match by idTag when both have idTag
            (nv.id_tag is not null and pv.id_tag is not null and pv.id_tag = nv.id_tag)
            or
            -- Match by charge_point_id when both don't have idTag (check if first charge_point_id in new visit is in previous visit's array)
            (nv.id_tag is null and pv.id_tag is null 
             and nv.charge_point_ids is not null
             and {{ array_size('nv.charge_point_ids') }} > 0
             and {{ array_contains('pv.charge_point_ids', 'nv.charge_point_ids[0]') }})
        )
        and nv.visit_start_ts > pv.visit_end_ts
        and nv.visit_start_ts <= {{ dbt.dateadd("minute", 
            case when nv.id_tag is not null then 30 else 2 end, 
            "pv.visit_end_ts") }}
),

merged_visits as (
    select
        coalesce(vtm.previous_visit_id, va.visit_id) as visit_id,
        va.location_id,
        va.id_tag,
        least(
            coalesce(pv.visit_start_ts, va.visit_start_ts),
            va.visit_start_ts
        ) as visit_start_ts,
        greatest(
            coalesce(pv.visit_end_ts, va.visit_end_ts),
            va.visit_end_ts
        ) as visit_end_ts,
        coalesce(pv.charge_attempt_count, 0) + va.charge_attempt_count as charge_attempt_count,
        array_distinct({{ array_concat('pv.charge_point_ids', 'va.charge_point_ids') }}) as charge_point_ids,
        array_distinct({{ array_concat('pv.connector_ids', 'va.connector_ids') }}) as connector_ids,
        array_distinct({{ array_concat('pv.transaction_ids', 'va.transaction_ids') }}) as transaction_ids,
        coalesce(pv.total_energy_transferred_kwh, 0) + va.total_energy_transferred_kwh as total_energy_transferred_kwh,
        {{ dbt.datediff('least(coalesce(pv.visit_start_ts, va.visit_start_ts), va.visit_start_ts)', 'greatest(coalesce(pv.visit_end_ts, va.visit_end_ts), va.visit_end_ts)', 'minute') }} as visit_duration_minutes
    from visits_aggregated va
    left join visits_to_merge vtm on va.visit_id = vtm.new_visit_id
    left join previous_visits pv on vtm.previous_visit_id = pv.visit_id
    
    union all
    
    -- Include previous visits that are not being merged
    select
        pv.visit_id,
        pv.location_id,
        pv.id_tag,
        pv.visit_start_ts,
        pv.visit_end_ts,
        pv.charge_attempt_count,
        pv.charge_point_ids,
        pv.connector_ids,
        pv.transaction_ids,
        pv.total_energy_transferred_kwh,
        pv.visit_duration_minutes
    from previous_visits pv
    where not exists (
        select 1 from visits_to_merge vtm where vtm.previous_visit_id = pv.visit_id
    )
)
{% endif %}

select
    {% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    mv.visit_id,
    mv.location_id,
    mv.id_tag,
    mv.visit_start_ts,
    mv.visit_end_ts,
    mv.charge_attempt_count,
    mv.charge_point_ids,
    mv.connector_ids,
    mv.transaction_ids,
    mv.total_energy_transferred_kwh,
    mv.visit_duration_minutes,
    {% else %}
    va.visit_id,
    va.location_id,
    va.id_tag,
    va.visit_start_ts,
    va.visit_end_ts,
    va.charge_attempt_count,
    va.charge_point_ids,
    va.connector_ids,
    va.transaction_ids,
    va.total_energy_transferred_kwh,
    va.visit_duration_minutes,
    {% endif %}
    (select incremental_ts from incremental) as incremental_ts
from 
{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    merged_visits mv
{% else %}
    visits_aggregated va
{% endif %}

