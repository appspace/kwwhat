{{
  config(
    materialized='incremental',
    unique_key=['date_id', 'charger_id', 'port_id', 'downtime_type'],
    incremental_strategy='delete+insert',
    cluster_by=['date_id', 'charger_id']
  )
}}

-- Grain is date_id + charger_id + port_id + downtime_type + reason, but the incremental key leaves reason out.
-- An in-progress outage's latest error code can change between runs, moving its minutes to a different
-- reason. delete+insert replaces the whole day/port/downtime_type slice, so the row under the old reason
-- is removed instead of left behind to double-count.

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

-- error_code_key read from dim_error_codes rather than generated in place: the dimension's key also
-- hashes the taxonomy's own error_code_name, which isn't on the outage row (it carries the OCPP
-- errorCode, not the vendor's name for the code)
error_codes as (
    select
        error_code_key,
        taxonomy,
        error_code,
        error_code_name
    from {{ ref('dim_error_codes') }}
),

-- Get faulted outages first to filter offline outages.
-- Codes are resolved per outage, before the daily aggregation, because the resolved name is part of
-- the grain: a charger can report a generic OCPP errorCode ('OtherError') with a vendor code that
-- names the actual fault (ChargeX CX003 = 'HighTemperature').
faulted_outages_resolved as (
    select
        f.charger_id,
        f.port_id,
        f.from_ts,
        f.to_ts,
        f.duration_minutes,
        -- As reported: the OCPP errorCode, which can be generic ('OtherError') when a vendor code names the fault
        f.latest_error_code_name as reported_error_code_name,
        -- As named in dim_error_codes; null when the code isn't in the dimension
        error_codes.error_code_name as latest_error_code_name,
        f.latest_error_code,
        f.latest_taxonomy,
        error_codes.error_code_key as latest_error_code_key,
        f.incremental_ts
    from {{ ref('int_faulted_outages') }} as f
    inner join ports as p
        on f.charger_id = p.charger_id
       and f.port_id = p.port_id
    -- Two mutually exclusive branches, so at most one dim_error_codes row matches:
    -- vendor code reported: (latest_taxonomy, latest_error_code), unique for vendor taxonomies;
    -- no vendor code: fall back to the OCPP 1.6 row for errorCode, unique on error_code_name there.
    -- Name matching is limited to ocpp1.6: a vendor's own names can collide with OCPP's
    -- (ChargeX CX002 is also 'GroundFailure') and would match the wrong code.
    left join error_codes
        on (
            f.latest_taxonomy = error_codes.taxonomy
            and f.latest_error_code = error_codes.error_code
        )
        or (
            f.latest_error_code is null
            and error_codes.taxonomy = 'ocpp1.6'
            and f.latest_error_code_name = error_codes.error_code_name
        )
    where f.incremental_ts > (select buffer_from_timestamp from incremental_date_range)
        and f.incremental_ts <= (select to_timestamp from incremental_date_range)
),

faulted_outages as (
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        duration_minutes,
        latest_error_code_key,
        incremental_ts,
        'FAULTED' as downtime_type,
        -- Every reported code takes its dim_error_codes name, never the raw errorCode - including OCPP's
        -- NoError sentinel, which is in the OCPP 1.6 seed. Nothing reported at all is labelled NoError too;
        -- codes missing from the dimension are UnknownError.
        case
            when latest_error_code is null and reported_error_code_name is null then 'NoError'
            when latest_error_code_key is null then 'UnknownError'
            else latest_error_code_name
        end as reason
    from faulted_outages_resolved
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
        cast(null as {{ dbt.type_string() }}) as latest_error_code_key,
        o.incremental_ts,
        'OFFLINE' as downtime_type,
        'NoHeartbeat' as reason
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
        latest_error_code_key,
        incremental_ts,
        downtime_type,
        reason
    from offline_outages
    union all
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        duration_minutes,
        latest_error_code_key,
        incremental_ts,
        downtime_type,
        reason
    from faulted_outages
),

filtered_outages as (
    select
        o.*,
        d.date_id
    from outages as o
    inner join {{ ref('dim_dates') }} as d
        on d.date_id between cast(o.from_ts as date) and cast(o.to_ts as date)
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
        o.downtime_type,
        o.reason,
        o.latest_error_code_key,
        -- date_id is DATE; cast so it compares with the timestamps on every warehouse
        greatest(o.from_ts, cast(o.date_id as {{ dbt.type_timestamp() }})) as interval_start,
        least(o.to_ts, {{ timestamp_add('day', 1, 'o.date_id') }}) as interval_end
    from filtered_outages as o
),

per_day as (
    select
        charger_id,
        port_id,
        date_id,
        downtime_type,
        reason,
        latest_error_code_key,
        interval_end,
        {{ dbt.datediff('interval_start', 'interval_end', 'minute') }} as duration_minutes
    from outage_days
),

final as (
    select
        date_id,
        charger_id,
        port_id,
        downtime_type,
        reason,
        sum(duration_minutes) as duration_minutes,
        {{ max_by('latest_error_code_key', 'interval_end') }} as latest_error_code_key
    from per_day
    group by 1, 2, 3, 4, 5
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
    {{ dbt_utils.generate_surrogate_key(['date_id', 'charger_id', 'port_id', 'downtime_type', 'reason']) }} as downtime_id,
    {{ dbt_utils.generate_surrogate_key(['charger_id', 'port_id']) }} as port_key,
    case when location_id is not null
        then {{ dbt_utils.generate_surrogate_key(['location_id']) }}
    end as location_key,
    latest_error_code_key,
    date_id,
    charger_id,
    port_id,
    downtime_type,
    reason,
    duration_minutes,
    (select incremental_ts from incremental) as incremental_ts
from final_with_keys
