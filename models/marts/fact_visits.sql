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
        ca.charge_attempt_id,
        ca.charge_point_id,
        p.port_id,
        ca.connector_id,
        ca.ingested_ts,
        ca.charge_attempt_unique_id,
        ca.transaction_id,
        ca.id_tags,
        ca.id_tag_statuses,
        ca.energy_transferred_kwh,
        p.location_id,
        ca.is_successful,
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

-- Step 1: Group attempts within 2 min on the same charger if not different idTags
anonymized_attempts_chaining as (
    select
        att.*,
        -- Find the previous attempt at the same charge point
        lag(ingested_ts) over (
            partition by charge_point_id
            order by ingested_ts
        ) as prev_attempt_ts,
        lag(id_tag) over (
            partition by charge_point_id
            order by ingested_ts
        ) as prev_id_tag,
        -- Find the next attempt at the same charge point
        lead(ingested_ts) over (
            partition by charge_point_id
            order by ingested_ts
        ) as next_attempt_ts,
        lead(id_tag) over (
            partition by charge_point_id
            order by ingested_ts
        ) as next_id_tag
    from charge_attempts_with_location att
),

anonymized_attempts_lag_lead as (
    select
        *,
        case
            -- Start of anonymized group: no previous attempt OR gap exceeds 2 minutes OR different idTags
            when prev_attempt_ts is null 
                or {{ dbt.datediff('prev_attempt_ts', 'ingested_ts', 'minute') }} > 2
                or (id_tag is not null and prev_id_tag is not null and id_tag != prev_id_tag)
            then True
            else False
        end as is_step1_group_start,
        case
            -- End of anonymized group: no next attempt OR gap exceeds 2 minutes OR different idTags
            when next_attempt_ts is null
                or {{ dbt.datediff('ingested_ts', 'next_attempt_ts', 'minute') }} > 2
                or (id_tag is not null and next_id_tag is not null and id_tag != next_id_tag)
            then True
            else False
        end as is_step1_group_end
    from anonymized_attempts_chaining
),

step1_group_boundaries as (
    select
        charge_point_id,
        ingested_ts as step1_group_start_ts,
        lead(ingested_ts) over (
            partition by charge_point_id
            order by ingested_ts
        ) as step1_group_end_ts
    from anonymized_attempts_lag_lead
    where is_step1_group_start = True
),

-- Assign attempts to anonymized groups and assign idTag if any attempt in group has one
attempts_with_inferred_id_tags as (
    select
        att.*,
        b.step1_group_start_ts,
        -- Assign idTag to whole group if any attempt in the group has an idTag
        max(att.id_tag) over (
            partition by att.charge_point_id, b.step1_group_start_ts
        ) as id_tag
    from step1_group_boundaries b
    inner join charge_attempts_with_location att
        on att.charge_point_id = b.charge_point_id
        and att.ingested_ts >= b.step1_group_start_ts
        and (b.step1_group_end_ts is null or att.ingested_ts < b.step1_group_end_ts)
),


-- Step 2: Group attempts by location_id + idTag, 30 min apart (if idTag exists), or by charge_point_id, 2 min apart (if no idTag)
attempts_with_grouping_strategies as (
    select
        att.*,
        -- Create grouping key: location_id + idTag (if idTag exists), otherwise charge_point_id
        case 
            when att.id_tag is not null 
            then att.location_id || '_' || att.id_tag
            else att.charge_point_id
        end as grouping_key,
        -- Determine time window: 30 minutes for authenticated visits, 2 minutes for unauthenticated visits
        case 
            when att.id_tag is not null then 30
            else 2
        end as time_window_minutes
    from attempts_with_inferred_id_tags att
),

attempts_chaining as (
    select
        att.*,
        -- Find the previous attempt in the same group
        lag(att.ingested_ts) over (
            partition by att.grouping_key
            order by att.ingested_ts
        ) as prev_attempt_ts,
        -- Find the next attempt in the same group
        lead(att.ingested_ts) over (
            partition by att.grouping_key
            order by att.ingested_ts
        ) as next_attempt_ts
    from attempts_with_grouping_strategies att
),

attempts_lag_lead as (
    select
        *,
        case
            -- Start of visit: no previous attempt OR gap exceeds time window
            when prev_attempt_ts is null 
                or {{ dbt.datediff('prev_attempt_ts', 'ingested_ts', 'minute') }} > time_window_minutes
            then True
            else False
        end as is_visit_start,
        case
            -- End of visit: no next attempt OR gap exceeds time window
            when next_attempt_ts is null
                or {{ dbt.datediff('ingested_ts', 'next_attempt_ts', 'minute') }} > time_window_minutes
            then True
            else False
        end as is_visit_end
    from attempts_chaining
),

visit_boundaries as (
    select
        grouping_key,
        location_id,
        id_tag,
        ingested_ts as visit_start_ts,
        lead(ingested_ts) over (
            partition by grouping_key
            order by ingested_ts
        ) as visit_end_ts
    from attempts_lag_lead
    where is_visit_start = True
),

attempts_grouping as (
    select
        att.charge_point_id,
        att.port_id,
        att.connector_id,
        att.ingested_ts,
        att.charge_attempt_unique_id,
        att.transaction_id,
        att.location_id,
        att.id_tag,
        att.id_tag_statuses,
        att.energy_transferred_kwh,
        att.is_successful,
        b.visit_start_ts,
        -- Mark if this is the first attempt in the visit
        visit_start_ts = ingested_ts as is_first_attempt,
        -- Mark if this is the last attempt in the visit
        row_number() over (
            partition by b.grouping_key, b.visit_start_ts
            order by att.ingested_ts desc
        ) = 1 as is_last_attempt
    from attempts_with_grouping_strategies att
    inner join visit_boundaries b
        on att.grouping_key = b.grouping_key
        and att.ingested_ts >= b.visit_start_ts
        and (b.visit_end_ts is null or att.ingested_ts < b.visit_end_ts)
),

new_visits as (
    select
        location_id,
        id_tag,
        min(ingested_ts) as visit_start_ts,
        max(ingested_ts) as visit_end_ts,
        count(*) as charge_attempt_count,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="charge_attempt_id") }}) as charge_attempt_ids,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="charge_point_id") }}) as charge_point_ids,
        sum(coalesce(energy_transferred_kwh, 0)) as total_energy_transferred_kwh,
        {{ dbt.datediff('min(ingested_ts)', 'max(ingested_ts)', 'minute') }} as visit_duration_minutes,
        max(case when is_last_attempt then is_successful else null end) as is_successful,
        min(case when is_first_attempt then charge_point_id else null end) as first_charge_point_id,
        max(case when is_last_attempt then charge_point_id else null end) as last_charge_point_id
    from attempts_grouping
    group by grouping_key, visit_start_ts
)

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}

    visits_buffer as (
        select
            visit_id,
            location_id,
            charge_point_ids,
            id_tag,
            visit_start_ts,
            visit_end_ts,
            charge_attempt_count,
            charge_attempt_ids,
            total_energy_transferred_kwh,
            visit_duration_minutes,
            last_charge_point_id,
            is_successful
        from {{ this }}
        where visit_end_ts >= (select buffer_from_timestamp from incremental_date_range)
    ),

    visits_buffer_with_inferred_id_tags as (
        select
            visit_id,
            location_id,
            charge_point_ids,
            coalesce(b.id_tag, auth.id_tag) as id_tag,
            visit_start_ts,
            visit_end_ts,
            charge_attempt_count,
            charge_attempt_ids,
            total_energy_transferred_kwh,
            visit_duration_minutes,
            last_charge_point_id,
            is_successful
        from visits_buffer b
        left join new_visits auth on b.id_tag is null  -- Only for unauthorized visits
            and auth.id_tag is not null
            -- Check if last charge_point_id from buffer matches first from new visit
            and b.last_charge_point_id = auth.first_charge_point_id
            and b.visit_end_ts < auth.visit_start_ts  -- New visit starts after old one ends
            and auth.visit_start_ts <= {{ dbt.dateadd("minute", 2, "b.visit_end_ts") }}  -- Within 2 minutes
    ),

    visits_buffer_with_grouping_strategies as (
        select *,
        case 
            when id_tag is not null 
                then location_id || '_' || id_tag
            else last_charge_point_id
        end as grouping_key
        from visits_buffer_with_inferred_id_tags
    ),

    -- Merge with previous visits that might need extension
    -- If a new visit starts within the time window of a previous visit's end, merge them
    -- For idTag-based visits: match by location_id and idTag
    -- For charge_point_id-based visits: match by location_id and check if charge_point_id is in previous visit's charge_point_ids array
    merged_visits as (
        select
            coalesce(b.visit_id, nv.visit_id) as visit_id,
            coalesce(b.location_id, nv.location_id) as location_id,
            coalesce(b.id_tag, nv.id_tag) as id_tag,
            coalesce(b.visit_start_ts, nv.visit_start_ts) as visit_start_ts,
            nv.visit_end_ts,
            coalesce(b.charge_attempt_count, 0) + nv.charge_attempt_count as charge_attempt_count,
            array_distinct({{ array_concat('b.charge_attempt_ids', 'nv.charge_attempt_ids') }}) as charge_attempt_ids,
            array_distinct({{ array_concat('b.charge_point_ids', 'nv.charge_point_ids') }}) as charge_point_ids,
            coalesce(b.total_energy_transferred_kwh, 0) + nv.total_energy_transferred_kwh as total_energy_transferred_kwh,
            nv.is_successful,
            coalesce(b.first_charge_point_id, nv.first_charge_point_id) as first_charge_point_id,
            nv.last_charge_point_id
        from new_visits nv
        left join visits_buffer_with_inferred_id_tags b
            on b.location_id = nv.location_id
            and b.grouping_key = nv.grouping_key
            and b.visit_end_ts < nv.visit_start_ts
            and nv.visit_start_ts <= {{ dbt.dateadd("minute", "nv.time_window_minutes", "b.visit_end_ts") }}
    ),

    visits as (
        select * from merged_visits
    )

{% else %}

    visits as (
        select * from new_visits
    )

{% endif %}

select
    visit_id,
    location_id,
    charge_point_ids,
    id_tag,
    visit_start_ts,
    visit_end_ts,
    charge_attempt_count,
    charge_attempt_ids,
    total_energy_transferred_kwh,
    last_charge_point_id,
    is_successful,
    {{ dbt.datediff('visit_start_ts', 'visit_end_ts', 'minute') }} as visit_duration_minutes,
    {{ dbt_utils.generate_surrogate_key(['location_id', 'first_charge_point_id', 'visit_start_ts']) }} as visit_id,
    (select incremental_ts from incremental) as incremental_ts
from visits

