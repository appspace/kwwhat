-- depends_on: {{ ref('fact_driver_activity_daily') }}
-- Evaluate the configured semantic expressions against independent driver-set classifications.
-- These synthetic cases exercise both window lengths without writing warehouse fixture tables.
{% if execute %}
    {% set retained_7 = graph.metrics['metric.kwwhat.retained_drivers_7d'].type_params.expr %}
    {% set retained_30 = graph.metrics['metric.kwwhat.retained_drivers_30d'].type_params.expr %}
    {% set resurrected_7 = graph.metrics['metric.kwwhat.resurrected_drivers_7d'].type_params.expr %}
    {% set resurrected_30 = graph.metrics['metric.kwwhat.resurrected_drivers_30d'].type_params.expr %}
    {% set churned_7 = graph.metrics['metric.kwwhat.churned_drivers_7d'].type_params.expr %}
    {% set churned_30 = graph.metrics['metric.kwwhat.churned_drivers_30d'].type_params.expr %}
{% else %}
    {% set retained_7 = '0' %}
    {% set retained_30 = '0' %}
    {% set resurrected_7 = '0' %}
    {% set resurrected_30 = '0' %}
    {% set churned_7 = '0' %}
    {% set churned_30 = '0' %}
{% endif %}

with window_sizes as (
    select 7 as window_days
    union all
    select 30 as window_days
),

fixtures as (
    select 'new' as driver_id, 0 as day_offset, false as boundary_offset
    union all select 'retained_without_today', -1, false
    union all select 'repeat', -2, false
    union all select 'repeat', 0, false
    union all select 'resurrected', -1, true
    union all select 'resurrected', 0, false
    union all select 'boundary_return', 0, true
    union all select 'boundary_return', 0, false
    union all select 'churned', 0, true
    union all select 'dormant', -1, true
),

scenarios as (
    select 'mixed' as scenario
    union all select 'no_new'
    union all select 'inactive'
),

activity_offsets as (
    select
        w.window_days,
        s.scenario,
        f.driver_id,
        case when f.boundary_offset then f.day_offset - w.window_days else f.day_offset end as day_offset,
    from window_sizes as w
    cross join fixtures as f
    cross join scenarios as s
    where s.scenario = 'mixed'
        or (s.scenario = 'no_new' and f.driver_id != 'new')
        or (s.scenario = 'inactive' and f.driver_id = 'dormant')
),

per_driver as (
    select
        window_days,
        scenario,
        driver_id,
        min(day_offset) as first_day_offset,
        max(case when day_offset between 1 - window_days and 0 then 1 else 0 end) as in_current,
        max(case when day_offset between -window_days and -1 then 1 else 0 end) as in_previous,
    from activity_offsets
    group by window_days, scenario, driver_id
),

set_counts as (
    select
        window_days,
        scenario,
        sum(in_current) as current_active,
        sum(in_previous) as previous_active,
        sum(case when in_current = 1 or in_previous = 1 then 1 else 0 end) as union_active,
        sum(case when first_day_offset = 0 then 1 else 0 end) as new_entrants,
        sum(case when in_current = 1 and in_previous = 1 then 1 else 0 end) as expected_retained,
        sum(case when in_current = 1 and in_previous = 0 and first_day_offset < 0 then 1 else 0 end) as expected_resurrected,
        sum(case when in_previous = 1 and in_current = 0 then 1 else 0 end) as expected_churned,
    from per_driver
    group by window_days, scenario
),

retained_results as (
    select
        window_days,
        scenario,
        current_active,
        previous_active,
        union_active,
        new_entrants,
        expected_retained,
        expected_resurrected,
        expected_churned,
        case when window_days = 7 then ({{ retained_7 }}) else ({{ retained_30 }}) end as retained,
    from set_counts
),

results as (
    select
        window_days,
        scenario,
        current_active,
        previous_active,
        new_entrants,
        retained,
        expected_retained,
        expected_resurrected,
        expected_churned,
        case when window_days = 7 then ({{ resurrected_7 }}) else ({{ resurrected_30 }}) end as resurrected,
        case when window_days = 7 then ({{ churned_7 }}) else ({{ churned_30 }}) end as churned,
    from retained_results
)

select
    window_days,
    scenario,
    retained,
    resurrected,
    churned,
from results
where retained is null
    or resurrected is null
    or churned is null
    or retained != expected_retained
    or resurrected != expected_resurrected
    or churned != expected_churned
    or current_active != new_entrants + retained + resurrected
    or current_active - previous_active != new_entrants + resurrected - churned

