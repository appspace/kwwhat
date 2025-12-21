{{
  config(
    materialized='incremental',
    unique_key=["charge_point_id", "port_id", "from_ts"], 
    incremental_strategy="merge",
    cluster_by="from_ts"
  )
}}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            least(
                {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }},
                (select max(incremental_ts) from {{ ref("int_status_changes") }})
            ) as to_timestamp
        from
            (
                select (select max(incremental_ts) from {{ this }}) as from_timestamp
            )
    ),

{% else %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }} as to_timestamp
        from
            (
                select cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}) as from_timestamp
            )
    ),
{% endif %}

-- Get status changes filtered to faulted status transitions
status_changes as (
    select
        charge_point_id,
        port_id,
        connector_id,
        ingested_ts,
        status,
        next_status,
        next_ingested_ts,
        incremental_ts
    from {{ ref("int_status_changes") }}
    where incremental_ts > (select from_timestamp from incremental_date_range)
        and incremental_ts <= (select to_timestamp from incremental_date_range)
),

incremental as (
    select
        max(ingested_ts) as incremental_ts
    from status_changes
),

ports_count as (
    select
        charge_point_id,
        port_id,
        count(distinct connector_id) as connector_count
    from {{ ref("stg_ports") }}
    group by 1, 2
),

-- Identify when status changes TO Faulted (start of fault period)
fault_periods as (
    select
        charge_point_id,
        port_id,
        connector_id,
        ingested_ts as from_ts,
        coalesce(next_ingested_ts, (select to_timestamp from incremental_date_range)) as to_ts
    from status_changes
    where status = 'Faulted'
),

-- Generate all distinct time points (from_ts and to_ts) per port
time_points as (
    select
        charge_point_id,
        port_id,
        from_ts as time_point
    from fault_periods
    
    union distinct
    
    select
        charge_point_id,
        port_id,
        to_ts as time_point
    from fault_periods
),

-- Create time intervals between consecutive time points per port
time_intervals as (
    select
        tp1.charge_point_id,
        tp1.port_id,
        tp1.time_point as from_ts,
        min(tp2.time_point) as to_ts
    from time_points tp1
    inner join time_points tp2
        on tp1.charge_point_id = tp2.charge_point_id
        and tp1.port_id = tp2.port_id
        and tp2.time_point > tp1.time_point
    group by 1, 2, 3
),

-- For each time interval, count how many connectors are faulted
intervals_with_faulted_count as (
    select
        ti.charge_point_id,
        ti.port_id,
        ti.from_ts,
        ti.to_ts,
        count(distinct fp.connector_id) as faulted_connector_count
    from time_intervals ti
    left join fault_periods fp
        on ti.charge_point_id = fp.charge_point_id
        and ti.port_id = fp.port_id
        and fp.from_ts <= ti.to_ts
        and fp.to_ts >= ti.from_ts
    group by 1, 2, 3, 4
),

-- Filter to intervals where all connectors are faulted
all_connectors_faulted as (
    select
        iwfc.charge_point_id,
        iwfc.port_id,
        iwfc.from_ts,
        iwfc.to_ts
    from intervals_with_faulted_count iwfc
    inner join ports_count pc
        on iwfc.charge_point_id = pc.charge_point_id
        and iwfc.port_id = pc.port_id
    where iwfc.faulted_connector_count = pc.connector_count
        and pc.connector_count > 0
),

-- Merge adjacent/overlapping periods where all connectors are faulted
faulted_outages_with_lag as (
    select
        charge_point_id,
        port_id,
        from_ts,
        to_ts,
        lag(to_ts) over (
            partition by charge_point_id, port_id 
            order by from_ts
        ) as prev_to_ts
    from all_connectors_faulted
),

faulted_outages_with_groups as (
    select
        charge_point_id,
        port_id,
        from_ts,
        to_ts,
        sum(case 
            when prev_to_ts >= from_ts then 0 
            else 1 
        end) over (
            partition by charge_point_id, port_id 
            order by from_ts
            rows unbounded preceding
        ) as group_id
    from faulted_outages_with_lag
),

faulted_outages as (
    select
        charge_point_id,
        port_id,
        min(from_ts) as from_ts,
        max(to_ts) as to_ts
    from faulted_outages_with_groups
    group by 1, 2, group_id
)

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}

-- We do not have to read a buffer of ongoing faults and update as we probably just re-read status changes for those faults 
-- and merge strategy will take care of the rest

{% else %}

-- Nothing to do here

{% endif %}

select 
    charge_point_id,
    port_id,
    from_ts,
    to_ts,
    {{ dbt.datediff('from_ts', 'to_ts', 'minutes') }} as duration_minutes,
    (select incremental_ts from incremental) as incremental_ts
from faulted_outages
where to_ts > from_ts

