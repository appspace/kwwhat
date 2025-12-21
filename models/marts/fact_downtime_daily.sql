{{
  config(
    materialized='incremental',
    unique_key=['date_id', 'charge_point_id', 'port_id', 'type'],
    incremental_strategy='merge',
    cluster_by=['date_id', 'charge_point_id']
  )
}}

{% if is_incremental() and adapter.get_relation(database=this.database, schema=this.schema, identifier=this.identifier) %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.date_trunc('day', 'from_timestamp') }} as buffer_from_timestamp,
            {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }} as to_timestamp
        from (
            select (select max(incremental_ts) from {{ this }}) as from_timestamp
        )
    ),
{% else %}
    with incremental_date_range as (
        select
            from_timestamp,
            {{ dbt.date_trunc('day', 'from_timestamp') }} as buffer_from_timestamp,
            {{ dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") }} as to_timestamp
        from (
            select cast( '{{ var("start_processing_date") }}' as {{ dbt.type_timestamp() }}) as from_timestamp
        )
    ),
{% endif %}

ports as (
    select
        charge_point_id,
        port_id,
        commissioned_ts,
        decommissioned_ts
    from {{ ref('stg_ports') }}
),

-- Get faulted outages first to filter offline outages
faulted_outages as (
    select
        charge_point_id,
        port_id,
        from_ts,
        to_ts,
        duration_minutes,
        incremental_ts,
        'FAULTED' as type
    from {{ ref('int_faulted_outages') }}
    where incremental_ts > (select buffer_from_timestamp from incremental_date_range)
        and incremental_ts <= (select to_timestamp from incremental_date_range)
),

-- for Offline outages (charge point level, need to join with ports)
-- Exclude the ones that started during a faulted outage - port reported faulted then went offline
offline_outages as (
    select
        o.charge_point_id,
        p.port_id,
        o.from_ts,
        o.to_ts,
        o.duration_minutes,
        o.incremental_ts,
        'OFFLINE' as type
    from {{ ref('int_offline_outages') }} o
    join ports p on o.charge_point_id = p.charge_point_id
    where o.incremental_ts > (select buffer_from_timestamp from incremental_date_range)
        and o.incremental_ts <= (select to_timestamp from incremental_date_range)
        and not exists (
            select 1
            from faulted_outages f
            where f.charge_point_id = o.charge_point_id
                and f.port_id = p.port_id
                and o.from_ts >= f.from_ts
                and o.from_ts < f.to_ts
        )
),

outages as (
    select * from offline_outages
    union all
    select * from faulted_outages
),

filtered_outages as (
    select
        o.*,
        d.date_id
    from outages o
    join {{ ref('dim_dates') }} d 
        on date_id between {{ dbt.date_trunc('day', 'o.from_ts') }} and {{ dbt.date_trunc('day', 'o.to_ts') }}
),

incremental as (
    select max(incremental_ts) as incremental_ts
    from filtered_outages
),

-- Compute per-day overlap
outage_days as (
    select
        o.charge_point_id,
        o.port_id,
        o.date_id,
        o.type,
        greatest(o.from_ts, o.date_id) as interval_start,
        least(o.to_ts, {{ dbt.dateadd('day', 1, "o.date_id") }}) as interval_end
    from filtered_outages o
),

per_day as (
    select
        charge_point_id,
        port_id,
        date_id,
        type,
        {{ dbt.datediff('interval_start', 'interval_end', 'minutes') }} as duration_minutes
    from outage_days
),

final as (
    select
        date_id,
        charge_point_id,
        port_id,
        type,
        sum(duration_minutes) as duration_minutes
    from per_day
    group by 1, 2, 3, 4
)

select *,
    (select incremental_ts from incremental) as incremental_ts
from final

