{{
  config(
    materialized='incremental',
    unique_key='outage_id',
    incremental_strategy='delete+insert',
    cluster_by=['date_id', 'charger_id'],
    post_hook="
      {%- set first_day_checked -%}
          (select cast({{ timestamp_add(var('incremental_window').unit, -var('incremental_window').length, 'max(date_id)') }} as date) from {{ this }})
      {%- endset -%}
      delete from {{ this }}
      where date_id >= {{ first_day_checked }}
          and outage_id in (
              select o.outage_id
              from {{ this }} as o
              inner join {{ this }} as f
                  on o.charger_id = f.charger_id
                  and o.port_id = f.port_id
                  and o.date_id = f.date_id
              where o.downtime_type = 'OFFLINE'
                  and f.downtime_type = 'FAULTED'
                  and o.outage_from_ts >= f.outage_from_ts
                  and o.outage_from_ts < f.outage_to_ts
                  and o.date_id >= {{ first_day_checked }}
          )
    "
  )
}}

-- Incremental strategy: delete+insert all daily rows for each changed outage_id.
-- Grain: one row per date_id + outage_id; outage_id remains stable while an ongoing outage is extended.
-- Watermark: the shared warehouse checkpoint supplies the bounded processing window.
-- Reprocessing: deleting by outage_id replaces every calendar day and the latest reason for a changed outage while
-- leaving unrelated outages untouched. A post-hook removes recent OFFLINE rows that begin during a FAULTED outage.
-- Changed outages are read by to_ts: a new, extended or closed outage always ends within the window that wrote it.
-- Late updates are captured when an upstream outage changes within a claimed checkpoint window.


with incremental_date_range as (
    {{ incremental_date_range() }}
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
        error_codes.error_code_key as latest_error_code_key
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
    where f.to_ts > (select from_timestamp from incremental_date_range)
        and f.to_ts <= (select to_timestamp from incremental_date_range)
),

faulted_outages as (
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        duration_minutes,
        latest_error_code_key,
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
offline_outages as (
    select
        o.charger_id,
        p.port_id,
        o.from_ts,
        o.to_ts,
        o.duration_minutes,
        cast(null as {{ dbt.type_string() }}) as latest_error_code_key,
        'OFFLINE' as downtime_type,
        'NoHeartbeat' as reason
    from {{ ref('int_offline_outages') }} as o
    inner join ports as p on o.charger_id = p.charger_id
    where o.to_ts > (select from_timestamp from incremental_date_range)
        and o.to_ts <= (select to_timestamp from incremental_date_range)
),

outages as (
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        duration_minutes,
        latest_error_code_key,
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
        downtime_type,
        reason
    from faulted_outages
),

-- One row per outage per calendar day it covers: the day starts before the outage ends, so an outage ending exactly
-- at midnight gets no row for the next day
filtered_outages as (
    select
        o.charger_id,
        o.port_id,
        o.from_ts,
        o.to_ts,
        o.latest_error_code_key,
        o.downtime_type,
        o.reason,
        d.date_id
    from outages as o
    inner join {{ ref('dim_dates') }} as d
        on d.date_id >= cast(o.from_ts as date)
        and cast(d.date_id as {{ dbt.type_timestamp() }}) < o.to_ts
),

-- Part of each outage that falls on each day
outage_days as (
    select
        charger_id,
        port_id,
        date_id,
        downtime_type,
        reason,
        latest_error_code_key,
        from_ts,
        to_ts,
        -- date_id is DATE; cast so it compares with the timestamps on every warehouse
        greatest(from_ts, cast(date_id as {{ dbt.type_timestamp() }})) as interval_start,
        least(to_ts, {{ timestamp_add('day', 1, 'date_id') }}) as interval_end
    from filtered_outages
),

-- charger_id -> location_id (int_chargers) -> location_key generated in place
outage_days_with_ids as (
    select
        {{ dbt_utils.generate_surrogate_key([
            'od.charger_id', 'od.port_id', 'od.downtime_type', 'od.from_ts'
        ]) }} as outage_id,
        od.charger_id,
        od.port_id,
        od.date_id,
        od.downtime_type,
        od.reason,
        od.latest_error_code_key,
        od.from_ts,
        od.to_ts,
        {{ dbt.datediff('od.interval_start', 'od.interval_end', 'minute') }} as duration_minutes,
        chargers.location_id
    from outage_days as od
    left join {{ ref('int_chargers') }} as chargers
        on od.charger_id = chargers.charger_id
)

select
    {{ dbt_utils.generate_surrogate_key(['date_id', 'outage_id']) }} as downtime_id,
    {{ dbt_utils.generate_surrogate_key(['charger_id', 'port_id']) }} as port_key,
    case when location_id is not null
        then {{ dbt_utils.generate_surrogate_key(['location_id']) }}
    end as location_key,
    latest_error_code_key,
    date_id,
    outage_id,
    charger_id,
    port_id,
    downtime_type,
    reason,
    from_ts as outage_from_ts,
    to_ts as outage_to_ts,
    duration_minutes
from outage_days_with_ids
