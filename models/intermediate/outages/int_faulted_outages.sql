{{
  config(
    materialized='incremental',
    unique_key=["charger_id", "port_id", "from_ts"],
    incremental_strategy="merge",
    cluster_by="from_ts"
  )
}}

-- Incremental strategy: merge one port outage per charger_id + port_id + from_ts.
-- Watermark: the shared warehouse checkpoint supplies the bounded processing window.
-- Reprocessing: reads status changes updated in the window (updated_ts) plus every still-open status, so an ongoing
-- fault is extended or closed; an ongoing fault ends at the last OCPP log in the window until its next status arrives.
-- Late arrivals are recoverable only when the affected status is updated in a later window or during a backfill.


with incremental_date_range as (
    {{ incremental_date_range() }}
),

-- Status changes updated in this window, plus every still-open status: an open fault on one connector must be seen
-- alongside a new fault on another to detect when all connectors of a port are faulted
status_changes as (
    select
        charger_id,
        port_id,
        connector_id,
        ingested_ts,
        status,
        error_code_name,
        error_code,
        taxonomy,
        next_status,
        next_ingested_ts
    from {{ ref("int_status_changes") }}
    where ingested_ts <= (select to_timestamp from incremental_date_range)
        and (
            next_status is null
            or (
                updated_ts > (select from_timestamp from incremental_date_range)
                and updated_ts <= (select to_timestamp from incremental_date_range)
            )
        )
),

-- Last OCPP log in this window, the same logs int_status_changes read: the end of every ongoing fault
last_log as (
    select
        max(ingested_timestamp) as last_log_ts
    from {{ ref("int_ocpp_logs") }}
    where ingested_timestamp > (select from_timestamp from incremental_date_range)
        and ingested_timestamp <= (select to_timestamp from incremental_date_range)
),

ports_count as (
    select
        charger_id,
        port_id,
        connector_count
    from {{ ref("int_ports") }}
),

-- Identify when status changes TO Faulted (start of fault period)
connector_fault_periods as (
    select
        charger_id,
        port_id,
        connector_id,
        error_code_name,
        error_code,
        taxonomy,
        ingested_ts as from_ts,
        coalesce(next_ingested_ts, (select last_log_ts from last_log)) as to_ts
    from status_changes
    where status = 'Faulted'
        and connector_id != '0'
),

-- Connector 0 reports for the charger as a whole and has no port_id: its fault periods apply to every port on the
-- charger, and end at connector 0's own next status
charger_fault_periods as (
    select
        sc.charger_id,
        con.port_id,
        con.connector_id,
        sc.error_code_name,
        sc.error_code,
        sc.taxonomy,
        sc.ingested_ts as from_ts,
        coalesce(sc.next_ingested_ts, (select last_log_ts from last_log)) as to_ts
    from status_changes as sc
    inner join {{ ref('int_connectors') }} as con
        on sc.charger_id = con.charger_id
    where sc.status = 'Faulted'
        and sc.connector_id = '0'
),

fault_periods as (
    select
        charger_id,
        port_id,
        connector_id,
        error_code_name,
        error_code,
        taxonomy,
        from_ts,
        to_ts
    from connector_fault_periods
    union all
    select
        charger_id,
        port_id,
        connector_id,
        error_code_name,
        error_code,
        taxonomy,
        from_ts,
        to_ts
    from charger_fault_periods
),

-- Generate all distinct time points (from_ts and to_ts) per port
time_points as (
    select
        charger_id,
        port_id,
        from_ts as time_point
    from fault_periods

    union distinct

    select
        charger_id,
        port_id,
        to_ts as time_point
    from fault_periods
),

-- Create time intervals between consecutive time points per port
time_intervals as (
    select
        tp1.charger_id,
        tp1.port_id,
        tp1.time_point as from_ts,
        min(tp2.time_point) as to_ts
    from time_points as tp1
    inner join time_points as tp2
        on tp1.charger_id = tp2.charger_id
        and tp1.port_id = tp2.port_id
        and tp2.time_point > tp1.time_point
    group by 1, 2, 3
),

-- For each time interval, count how many connectors are faulted. Overlap is strict: a fault that only starts at the
-- interval's end, or ends at its start, doesn't count
intervals_with_faulted_count as (
    select
        ti.charger_id,
        ti.port_id,
        ti.from_ts,
        ti.to_ts,
        count(distinct fp.connector_id) as faulted_connector_count
    from time_intervals as ti
    left join fault_periods as fp
        on ti.charger_id = fp.charger_id
        and ti.port_id = fp.port_id
        and fp.from_ts < ti.to_ts
        and fp.to_ts > ti.from_ts
    group by 1, 2, 3, 4
),

-- Filter to intervals where all connectors are faulted
all_connectors_faulted as (
    select
        iwfc.charger_id,
        iwfc.port_id,
        iwfc.from_ts,
        iwfc.to_ts
    from intervals_with_faulted_count as iwfc
    inner join ports_count as pc
        on iwfc.charger_id = pc.charger_id
        and iwfc.port_id = pc.port_id
    where iwfc.faulted_connector_count = pc.connector_count
        and pc.connector_count > 0
),

-- Merge adjacent/overlapping periods where all connectors are faulted
faulted_outages_with_lag as (
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        lag(to_ts) over (
            partition by charger_id, port_id
            order by from_ts
        ) as prev_to_ts
    from all_connectors_faulted
),

faulted_outages_with_groups as (
    select
        charger_id,
        port_id,
        from_ts,
        to_ts,
        sum(case
            when prev_to_ts >= from_ts then 0
            else 1
        end) over (
            partition by charger_id, port_id
            order by from_ts
            rows unbounded preceding
        ) as group_id
    from faulted_outages_with_lag
),

faulted_outages as (
    select
        charger_id,
        port_id,
        min(from_ts) as from_ts,
        max(to_ts) as to_ts
    from faulted_outages_with_groups
    group by 1, 2, group_id
),

-- Root cause: fault codes from the connector fault period that started most recently during the outage
faulted_outages_with_root_cause as (
    select
        fo.charger_id,
        fo.port_id,
        fo.from_ts,
        fo.to_ts,
        {{ max_by('fp.error_code_name', 'fp.from_ts') }} as latest_error_code_name,
        {{ max_by('fp.error_code', 'fp.from_ts') }} as latest_error_code,
        {{ max_by('fp.taxonomy', 'fp.from_ts') }} as latest_taxonomy
    from faulted_outages as fo
    left join fault_periods as fp
        on fo.charger_id = fp.charger_id
        and fo.port_id = fp.port_id
        and fp.from_ts < fo.to_ts
        and fp.to_ts > fo.from_ts
    group by fo.charger_id, fo.port_id, fo.from_ts, fo.to_ts
)

select
    charger_id,
    port_id,
    from_ts,
    to_ts,
    {{ dbt.datediff('from_ts', 'to_ts', 'minute') }} as duration_minutes,
    latest_error_code_name,
    latest_error_code,
    latest_taxonomy
from faulted_outages_with_root_cause
where to_ts > from_ts
