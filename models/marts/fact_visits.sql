{{
  config(
    materialized='incremental',
    unique_key=["location_id", "first_charger_id", "first_port_id", "visit_start_ts"],
    incremental_strategy="merge",
    cluster_by="visit_start_ts"
  )
}}

{%- if is_incremental() -%}
    {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
{%- else -%}
    {%- set from_ts_caps = ["cast( '" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")"] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(
        from_timestamp_caps=from_ts_caps,
        buffer_minutes=30,
        to_timestamp_caps=["(select max(incremental_ts) from " ~ ref("fact_charge_attempts") ~ ")"]
    ) }}
),

-- Get charge attempts with location information
charge_attempts_with_location as (
    select
        att.charge_attempt_id,
        att.charger_id,
        ch.location_id,
        c.port_id,
        att.connector_id,
        att.charge_attempt_start_ts,
        att.charge_attempt_stop_ts,
        att.id_tags,
        att.id_tag_statuses,
        att.energy_transferred_kwh,
        att.is_successful,
        att.preparing_ingested_ts,
        att.id_tag
    from {{ ref("fact_charge_attempts") }} as att
    inner join {{ ref("dim_connectors") }} as c
        on att.charger_id = c.charger_id
        and att.connector_id = c.connector_id
    inner join {{ ref("dim_chargers") }} as ch
        on att.charger_id = ch.charger_id
    where att.incremental_ts > (select from_timestamp from incremental_date_range)
        and att.incremental_ts <= (select to_timestamp from incremental_date_range)
),

incremental as (
    select
        max(preparing_ingested_ts) as incremental_ts
    from charge_attempts_with_location
),

-- Step 1: Infer idTag for unauthorised attempts if there is authorised right after on the same port
unauthorised_attempts_chaining as (
    select
        att.*,
        -- Find the previous attempt at the same charge point and port
        lag(charge_attempt_stop_ts) over (
            partition by charger_id, port_id
            order by charge_attempt_start_ts
        ) as prev_attempt_stop_ts,
        lag(charge_attempt_start_ts) over (
            partition by charger_id, port_id
            order by charge_attempt_start_ts
        ) as prev_attempt_start_ts,
        lag(id_tag) over (
            partition by charger_id, port_id
            order by charge_attempt_start_ts
        ) as prev_id_tag,
        -- Find the next attempt at the same charge point and port
        lead(charge_attempt_start_ts) over (
            partition by charger_id, port_id
            order by charge_attempt_start_ts
        ) as next_attempt_start_ts,
        lead(id_tag) over (
            partition by charger_id, port_id
            order by charge_attempt_start_ts
        ) as next_id_tag
    from charge_attempts_with_location as att
),

unauthorised_attempts_lag_lead as (
    select
        *,
        case
            -- Start of new group: no previous attempt OR gap from prev stop to current start exceeds 2 minutes OR different idTags
            when prev_attempt_stop_ts is null
                or {{ dbt.datediff('prev_attempt_stop_ts', 'charge_attempt_start_ts', 'minute') }} > 2
                or (id_tag is not null and prev_id_tag is not null and id_tag != prev_id_tag)
            then true
            else false
        end as is_step1_group_start,
        case
            -- End of new group: no next attempt OR gap from current stop to next start exceeds 2 minutes OR different idTags
            when next_attempt_start_ts is null
                or {{ dbt.datediff('charge_attempt_stop_ts', 'next_attempt_start_ts', 'minute') }} > 2
                or (id_tag is not null and next_id_tag is not null and id_tag != next_id_tag)
            then true
            else false
        end as is_step1_group_end
    from unauthorised_attempts_chaining
),

step1_group_boundaries as (
    select
        charger_id,
        port_id,
        charge_attempt_start_ts as step1_group_start_ts,
        lead(charge_attempt_start_ts) over (
            partition by charger_id, port_id
            order by charge_attempt_start_ts
        ) as step1_group_end_ts
    from unauthorised_attempts_lag_lead
    where is_step1_group_start = true
),

-- Assign attempts to unauthorised groups and assign idTag if any attempt in group has one
attempts_with_inferred_id_tags as (
    select
        att.charge_attempt_id,
        att.charger_id,
        att.port_id,
        att.connector_id,
        att.charge_attempt_start_ts,
        att.charge_attempt_stop_ts,
        att.id_tags,
        att.id_tag_statuses,
        att.energy_transferred_kwh,
        att.location_id,
        att.is_successful,
        b.step1_group_start_ts,
        -- Assign idTag to whole group if any attempt in the group has an idTag
        max(att.id_tag) over (
            partition by att.charger_id, att.port_id, b.step1_group_start_ts
        ) as id_tag
    from step1_group_boundaries as b
    inner join charge_attempts_with_location as att
        on att.charger_id = b.charger_id
        and att.port_id = b.port_id
        and att.charge_attempt_start_ts >= b.step1_group_start_ts
        and (b.step1_group_end_ts is null or att.charge_attempt_start_ts < b.step1_group_end_ts)
),


-- Step 2: Group attempts by location_id + idTag, 30 min apart (if idTag exists), or by location_id + charger_id + port_id, 2 min apart (if no idTag)
attempts_with_grouping_strategies as (
    select
        att.*,
        -- Create grouping key: location_id + idTag (if idTag exists), otherwise location_id + charger_id + port_id
        case
            when att.id_tag is not null
            then att.location_id || '_' || att.id_tag
            else att.location_id || '_' || att.charger_id || '_' || att.port_id
        end as grouping_key,
        -- Determine time window: 30 minutes for authenticated visits, 2 minutes for unauthenticated visits
        case
            when att.id_tag is not null then 30
            else 2
        end as time_window_minutes
    from attempts_with_inferred_id_tags as att
),

attempts_chaining as (
    select
        att.*,
        -- Find the previous attempt's stop time in the same group
        lag(att.charge_attempt_stop_ts) over (
            partition by att.grouping_key
            order by att.charge_attempt_start_ts
        ) as prev_attempt_stop_ts,
        -- Find the next attempt's start time in the same group
        lead(att.charge_attempt_start_ts) over (
            partition by att.grouping_key
            order by att.charge_attempt_start_ts
        ) as next_attempt_start_ts
    from attempts_with_grouping_strategies as att
),

attempts_lag_lead as (
    select
        *,
        case
            -- Start of visit: no previous attempt OR gap from prev stop to current start exceeds time window
            when prev_attempt_stop_ts is null
                or {{ dbt.datediff('prev_attempt_stop_ts', 'charge_attempt_start_ts', 'minute') }} > time_window_minutes
            then true
            else false
        end as is_visit_start,
        case
            -- End of visit: no next attempt OR gap from current stop to next start exceeds time window
            when next_attempt_start_ts is null
                or {{ dbt.datediff('charge_attempt_stop_ts', 'next_attempt_start_ts', 'minute') }} > time_window_minutes
            then true
            else false
        end as is_visit_end
    from attempts_chaining
),

visit_boundaries as (
    select
        grouping_key,
        time_window_minutes,
        location_id,
        id_tag,
        charge_attempt_start_ts as visit_start_ts,
        lead(charge_attempt_start_ts) over (
            partition by grouping_key
            order by charge_attempt_start_ts
        ) as next_visit_start_ts
    from attempts_lag_lead
    where is_visit_start = true
),

attempts_grouping as (
    select
        att.charge_attempt_id,
        att.charger_id,
        att.port_id,
        att.connector_id,
        att.charge_attempt_start_ts,
        att.charge_attempt_stop_ts,
        att.location_id,
        att.id_tag,
        att.id_tag_statuses,
        att.energy_transferred_kwh,
        att.is_successful,
        b.visit_start_ts,
        att.grouping_key,
        att.time_window_minutes,
        -- Mark if this is the first attempt in the visit
        visit_start_ts = charge_attempt_start_ts as is_first_attempt,
        -- Mark if this is the last attempt in the visit
        row_number() over (
            partition by b.grouping_key, b.visit_start_ts
            order by att.charge_attempt_start_ts desc
        ) = 1 as is_last_attempt
    from attempts_with_grouping_strategies as att
    inner join visit_boundaries as b
        on att.grouping_key = b.grouping_key
        and att.charge_attempt_start_ts >= b.visit_start_ts
        and (b.next_visit_start_ts is null or att.charge_attempt_start_ts < b.next_visit_start_ts)
),

new_visits as (
    select
        grouping_key,
        time_window_minutes,
        visit_start_ts,
        max(id_tag) as id_tag,
        max(location_id) as location_id,
        max(charge_attempt_stop_ts) as visit_end_ts,
        count(*) as charge_attempt_count,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="charge_attempt_id") }}) as charge_attempt_ids,
        array_distinct({{ fivetran_utils.array_agg(field_to_agg="charger_id") }}) as charger_ids,
        sum(coalesce(energy_transferred_kwh, 0)) as total_energy_transferred_kwh,
        {{ dbt.datediff(
            'min(charge_attempt_start_ts)',
            'max(charge_attempt_stop_ts)',
            'minute'
        ) }} as visit_duration_minutes,
        max(case when is_last_attempt then is_successful end) as is_successful,
        min(case when is_first_attempt then charge_attempt_id end) as first_charge_attempt_id,
        max(case when is_last_attempt then charge_attempt_id end) as last_charge_attempt_id,
        min(case when is_first_attempt then charger_id end) as first_charger_id,
        max(case when is_last_attempt then charger_id end) as last_charger_id,
        min(case when is_first_attempt then port_id end) as first_port_id,
        max(case when is_last_attempt then port_id end) as last_port_id
    from attempts_grouping
    group by grouping_key, time_window_minutes, visit_start_ts
),

{% if is_incremental() %}

    visits_buffer as (
        select
            visit_id,
            location_id,
            charger_ids,
            id_tag,
            visit_start_ts,
            visit_end_ts,
            charge_attempt_count,
            charge_attempt_ids,
            total_energy_transferred_kwh,
            visit_duration_minutes,
            first_charge_attempt_id,
            first_charger_id,
            first_port_id,
            last_charge_attempt_id,
            last_charger_id,
            last_port_id,
            is_successful,
            grouping_key
        from {{ this }}
        where visit_end_ts >= (select buffer_from_timestamp from incremental_date_range)
    ),

    visits_buffer_with_inferred_id_tags as (
        select
            b.visit_id,
            b.location_id,
            b.charger_ids,
            coalesce(b.id_tag, auth.id_tag) as id_tag,
            b.visit_start_ts,
            b.visit_end_ts,
            b.charge_attempt_count,
            b.charge_attempt_ids,
            b.total_energy_transferred_kwh,
            b.visit_duration_minutes,
            b.first_charge_attempt_id,
            b.last_charge_attempt_id,
            b.first_charger_id,
            b.last_charger_id,
            b.first_port_id,
            b.last_port_id,
            b.is_successful
        from visits_buffer b
        left join new_visits auth on b.id_tag is null  -- Only for unauthorized visits
            and auth.id_tag is not null
            -- Check if last charger_id and port_id from buffer match first from new visit
            and b.last_charger_id = auth.first_charger_id
            and b.last_port_id = auth.first_port_id
            and b.visit_end_ts < auth.visit_start_ts  -- New visit starts after old one ends
            and auth.visit_start_ts <= {{ dbt.dateadd("minute", 2, "b.visit_end_ts") }}  -- Within 2 minutes
    ),

    visits_buffer_with_grouping_strategies as (
        select
            visit_id,
            location_id,
            charger_ids,
            id_tag,
            visit_start_ts,
            visit_end_ts,
            charge_attempt_count,
            charge_attempt_ids,
            total_energy_transferred_kwh,
            visit_duration_minutes,
            first_charge_attempt_id,
            last_charge_attempt_id,
            first_charger_id,
            last_charger_id,
            first_port_id,
            last_port_id,
            is_successful,
            case
                when id_tag is not null
                    then location_id || '_' || id_tag
                else location_id || '_' || last_charger_id || '_' || last_port_id
            end as grouping_key
        from visits_buffer_with_inferred_id_tags
    ),

    -- Merge with previous visits that might need extension
    -- If a new visit starts within the time window of a previous visit's end, merge them
    -- For idTag-based visits: match by location_id and idTag
    -- For unauthorized visits: match by location_id, charger_id, and port_id
    merged_visits as (
        select
            coalesce(b.location_id, nv.location_id) as location_id,
            coalesce(b.id_tag, nv.id_tag) as id_tag,
            coalesce(b.visit_start_ts, nv.visit_start_ts) as visit_start_ts,
            nv.visit_end_ts,
            coalesce(b.charge_attempt_count, 0) + nv.charge_attempt_count as charge_attempt_count,
            array_distinct({{ array_concat('b.charge_attempt_ids', 'nv.charge_attempt_ids') }}) as charge_attempt_ids,
            array_distinct({{ array_concat('b.charger_ids', 'nv.charger_ids') }}) as charger_ids,
            coalesce(b.total_energy_transferred_kwh, 0) + nv.total_energy_transferred_kwh as total_energy_transferred_kwh,
            nv.is_successful,
            coalesce(b.first_charge_attempt_id, nv.first_charge_attempt_id) as first_charge_attempt_id,
            nv.last_charge_attempt_id,
            coalesce(b.first_charger_id, nv.first_charger_id) as first_charger_id,
            nv.last_charger_id,
            coalesce(b.first_port_id, nv.first_port_id) as first_port_id,
            nv.last_port_id,
            nv.grouping_key
        from new_visits nv
        left join visits_buffer_with_grouping_strategies b
            on b.grouping_key = nv.grouping_key
            and b.visit_end_ts < nv.visit_start_ts
            and nv.visit_start_ts <= {{ dbt.dateadd("minute", "nv.time_window_minutes", "b.visit_end_ts") }}
    ),

    visits as (
        select
            location_id,
            id_tag,
            visit_start_ts,
            visit_end_ts,
            charge_attempt_count,
            charge_attempt_ids,
            charger_ids,
            total_energy_transferred_kwh,
            is_successful,
            first_charge_attempt_id,
            last_charge_attempt_id,
            first_charger_id,
            last_charger_id,
            first_port_id,
            last_port_id,
            grouping_key
        from merged_visits
    )

{% else %}

    visits as (
        select
            location_id,
            id_tag,
            visit_start_ts,
            visit_end_ts,
            charge_attempt_count,
            charge_attempt_ids,
            charger_ids,
            total_energy_transferred_kwh,
            is_successful,
            first_charge_attempt_id,
            last_charge_attempt_id,
            first_charger_id,
            last_charger_id,
            first_port_id,
            last_port_id,
            grouping_key
        from new_visits
    )

{% endif %}

select
    {{ dbt_utils.generate_surrogate_key([
        'v.location_id', 'v.first_charger_id', 'v.first_port_id', 'v.visit_start_ts'
    ]) }} as visit_id,
    {{ dbt_utils.generate_surrogate_key(['v.location_id']) }} as location_key,
    {{ dbt_utils.generate_surrogate_key(["coalesce(v.id_tag, 'UNKNOWN')"]) }} as driver_key,
    {{ dbt_utils.generate_surrogate_key(['v.first_charger_id', 'v.first_port_id']) }} as first_port_key,
    {{ dbt_utils.generate_surrogate_key(['v.last_charger_id', 'v.last_port_id']) }} as last_port_key,
    v.location_id,
    v.charger_ids,
    v.id_tag,
    v.visit_start_ts,
    v.visit_end_ts,
    v.charge_attempt_count,
    v.charge_attempt_ids,
    v.total_energy_transferred_kwh,
    v.first_charge_attempt_id,
    v.last_charge_attempt_id,
    v.first_charger_id,
    v.last_charger_id,
    v.first_port_id,
    v.last_port_id,
    v.is_successful,
    v.grouping_key,
    {{ dbt.datediff('v.visit_start_ts', 'v.visit_end_ts', 'minute') }} as visit_duration_minutes,
    (select incremental_ts from incremental) as incremental_ts
from visits as v

