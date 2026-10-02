{{
  config(
    materialized='incremental',
    unique_key=["charger_id", "port_id", "from_ts"],
    incremental_strategy="merge",
    cluster_by="from_ts"
  )
}}

-- Incremental merge. int_status_changes writes every open status again on each run, so an ongoing fault is read
-- again on every run and extended (or closed once its next status arrives); the merge upserts it by from_ts.
-- One clock: int_status_changes.incremental_ts selects the batch, and its max is both the end of every ongoing fault
-- and this batch's incremental_ts, so the next run starts where an ongoing fault was cut off.

{% if is_incremental() -%}
    {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
{%- else -%}
    {#- Start where int_status_changes starts (the first log, not start_processing_date), so this model's first
        window ends where the upstream's first batch ends and that batch's incremental_ts is inside it -#}
    {%- set start_ts = "cast( '" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")" -%}
    {%- set from_ts_caps = [
        start_ts,
        "coalesce((select min(ingested_timestamp) from " ~ ref("int_ocpp_logs") ~ "), " ~ start_ts ~ ")"
    ] -%}
{%- endif -%}

with incremental_date_range as (
    {{ incremental_date_range(
        from_timestamp_caps=from_ts_caps,
        to_timestamp_caps=["(select max(incremental_ts) from " ~ ref("int_status_changes") ~ ")"]
    ) }}
),

-- Get status changes filtered to faulted status transitions
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
        next_ingested_ts,
        incremental_ts
    from {{ ref("int_status_changes") }}
    where incremental_ts > (select from_timestamp from incremental_date_range)
        and incremental_ts <= (select to_timestamp from incremental_date_range)
),

-- Last log received upstream: int_status_changes stamps each batch with max(ingested_timestamp) of the OCPP logs it read
incremental as (
    select
        max(incremental_ts) as incremental_ts
    from status_changes
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
        coalesce(next_ingested_ts, (select incremental_ts from incremental)) as to_ts
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
        coalesce(sc.next_ingested_ts, (select incremental_ts from incremental)) as to_ts
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
    latest_taxonomy,
    (select incremental_ts from incremental) as incremental_ts
from faulted_outages_with_root_cause
where to_ts > from_ts
