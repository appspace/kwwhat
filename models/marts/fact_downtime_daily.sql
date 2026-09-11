{{
  config(
    materialized='incremental',
    unique_key=['date_id', 'charger_id', 'port_id', 'reason'],
    incremental_strategy='merge',
    cluster_by=['date_id', 'charger_id']
  )
}}

{%- if is_incremental() -%}
    {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
{%- else -%}
    {%- set from_ts_caps = ["cast( '" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")"] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(from_timestamp_caps=from_ts_caps, buffer_minutes=1440) }}
),

ports as (
    select
        charger_id,
        port_id
    from {{ ref('int_ports') }}
),

-- Get faulted outages first to filter offline outages
faulted_outages as (
    select
        f.charger_id,
        f.port_id,
        f.from_ts,
        f.to_ts,
        f.duration_minutes,
        f.error_codes,
        f.vendor_error_codes,
        f.vendor_ids as taxonomies,
        f.incremental_ts,
        'FAULTED' as reason
    from {{ ref('int_faulted_outages') }} as f
    inner join ports as p
        on f.charger_id = p.charger_id
       and f.port_id = p.port_id
    where f.incremental_ts > (select buffer_from_timestamp from incremental_date_range)
        and f.incremental_ts <= (select to_timestamp from incremental_date_range)
),

-- for Offline outages (charge point level, need to join with ports)
-- Exclude the ones that started during a faulted outage - port reported faulted then went offline
offline_outages as (
    select
        o.charger_id,
        p.port_id,
        o.from_ts,
        o.to_ts,
        o.duration_minutes,
        cast(null as array) as error_codes,
        cast(null as array) as vendor_error_codes,
        cast(null as array) as taxonomies,
        o.incremental_ts,
        'OFFLINE' as reason
    from {{ ref('int_offline_outages') }} as o
    inner join ports as p on o.charger_id = p.charger_id
    where o.incremental_ts > (select buffer_from_timestamp from incremental_date_range)
        and o.incremental_ts <= (select to_timestamp from incremental_date_range)
        and not exists (
            select 1
            from faulted_outages as f
            where f.charger_id = o.charger_id
                and f.port_id = p.port_id
                and o.from_ts >= f.from_ts
                and o.from_ts < f.to_ts
        )
),

outages as (
    select charger_id, port_id, from_ts, to_ts, duration_minutes, error_codes, vendor_error_codes, taxonomies, incremental_ts, reason from offline_outages
    union all
    select charger_id, port_id, from_ts, to_ts, duration_minutes, error_codes, vendor_error_codes, taxonomies, incremental_ts, reason from faulted_outages
),

filtered_outages as (
    select
        o.*,
        d.date_id
    from outages as o
    inner join {{ ref('dim_dates') }} as d
        on date_id between {{ dbt.date_trunc('day', 'o.from_ts') }} and {{ dbt.date_trunc('day', 'o.to_ts') }}
),

incremental as (
    select max(incremental_ts) as incremental_ts
    from filtered_outages
),

-- Compute per-day overlap
outage_days as (
    select
        o.charger_id,
        o.port_id,
        o.date_id,
        o.reason,
        o.error_codes,
        o.vendor_error_codes,
        o.taxonomies,
        greatest(o.from_ts, o.date_id) as interval_start,
        least(o.to_ts, {{ dbt.dateadd('day', 1, 'o.date_id') }}) as interval_end
    from filtered_outages as o
),

per_day as (
    select
        charger_id,
        port_id,
        date_id,
        reason,
        error_codes,
        vendor_error_codes,
        taxonomies,
        {{ dbt.datediff('interval_start', 'interval_end', 'minutes') }} as duration_minutes
    from outage_days
),

final as (
    select
        date_id,
        charger_id,
        port_id,
        reason,
        sum(duration_minutes) as duration_minutes,
        {{ array_concat_agg_distinct('error_codes') }} as error_codes,
        {{ array_concat_agg_distinct('vendor_error_codes') }} as vendor_error_codes,
        {{ array_concat_agg_distinct('taxonomies') }} as taxonomies
    from per_day
    group by 1, 2, 3, 4
),

-- charger_id -> location_id (int_chargers) -> location_key generated in place
final_with_keys as (
    select
        final.*,
        chargers.location_id
    from final
    left join {{ ref('int_chargers') }} as chargers
        on final.charger_id = chargers.charger_id
)

select
    -- Generate a deterministic unique ID from the composite key
    {{ dbt_utils.generate_surrogate_key(['date_id', 'charger_id', 'port_id', 'reason']) }} as downtime_id,
    {{ dbt_utils.generate_surrogate_key(['charger_id', 'port_id']) }} as port_key,
    case when location_id is not null
        then {{ dbt_utils.generate_surrogate_key(['location_id']) }}
    end as location_key,
    date_id,
    charger_id,
    port_id,
    reason,
    duration_minutes,
    error_codes,
    vendor_error_codes,
    taxonomies,
    (select incremental_ts from incremental) as incremental_ts
from final_with_keys
