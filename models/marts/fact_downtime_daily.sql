{{
  config(
    materialized='incremental',
    unique_key=['date_id', 'charger_id', 'port_id', 'reason'],
    incremental_strategy='merge',
    cluster_by=['date_id', 'charger_id']
  )
}}

-- Incremental merge: no buffer - relies on dbt's merge upsert alone.

{% if is_incremental() -%}
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
        f.latest_error_code_name,
        f.latest_error_code,
        f.latest_taxonomy,
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
        cast(null as {{ dbt.type_string() }}) as latest_error_code_name,
        cast(null as {{ dbt.type_string() }}) as latest_error_code,
        cast(null as {{ dbt.type_string() }}) as latest_taxonomy,
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
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        duration_minutes,
        latest_error_code_name,
        latest_error_code,
        latest_taxonomy,
        incremental_ts,
        reason
    from offline_outages
    union all
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        duration_minutes,
        latest_error_code_name,
        latest_error_code,
        latest_taxonomy,
        incremental_ts,
        reason
    from faulted_outages
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
        o.latest_error_code_name,
        o.latest_error_code,
        o.latest_taxonomy,
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
        latest_error_code_name,
        latest_error_code,
        latest_taxonomy,
        interval_end,
        {{ dbt.datediff('interval_start', 'interval_end', 'minute') }} as duration_minutes
    from outage_days
),

final as (
    select
        date_id,
        charger_id,
        port_id,
        reason,
        sum(duration_minutes) as duration_minutes,
        {{ max_by('latest_error_code_name', 'interval_end') }} as latest_error_code_name,
        {{ max_by('latest_error_code', 'interval_end') }} as latest_error_code,
        {{ max_by('latest_taxonomy', 'interval_end') }} as latest_taxonomy
    from per_day
    group by 1, 2, 3, 4
),

-- error_code_key read from dim_error_codes rather than generated in place: the dimension's key also
-- hashes the taxonomy's own error_code_name, which isn't on this row (latest_error_code_name is the
-- OCPP errorCode, not the vendor's name for the code)
error_codes as (
    select
        error_code_key,
        taxonomy,
        error_code,
        error_code_name
    from {{ ref('dim_error_codes') }}
),

-- charger_id -> location_id (int_chargers) -> location_key generated in place
final_with_keys as (
    select
        final.*,
        chargers.location_id,
        error_codes.error_code_key as latest_error_code_key
    from final
    left join {{ ref('int_chargers') }} as chargers
        on final.charger_id = chargers.charger_id
    -- Two mutually exclusive branches, so at most one dim_error_codes row matches:
    -- vendor code reported -> (latest_taxonomy, latest_error_code), unique for vendor taxonomies;
    -- no vendor code -> fall back to the OCPP 1.6 row for errorCode, unique on error_code_name there.
    -- Name matching is limited to ocpp1.6: a vendor's own names can collide with OCPP's
    -- (ChargeX CX002 is also 'GroundFailure') and would match the wrong code.
    left join error_codes
        on (
            final.latest_taxonomy = error_codes.taxonomy
            and final.latest_error_code = error_codes.error_code
        )
        or (
            final.latest_error_code is null
            and error_codes.taxonomy = 'ocpp1.6'
            and final.latest_error_code_name = error_codes.error_code_name
        )
)

select
    -- Generate a deterministic unique ID from the composite key
    {{ dbt_utils.generate_surrogate_key(['date_id', 'charger_id', 'port_id', 'reason']) }} as downtime_id,
    {{ dbt_utils.generate_surrogate_key(['charger_id', 'port_id']) }} as port_key,
    case when location_id is not null
        then {{ dbt_utils.generate_surrogate_key(['location_id']) }}
    end as location_key,
    latest_error_code_key,
    date_id,
    charger_id,
    port_id,
    reason,
    duration_minutes,
    latest_error_code_name,
    latest_error_code,
    latest_taxonomy,
    (select incremental_ts from incremental) as incremental_ts
from final_with_keys
