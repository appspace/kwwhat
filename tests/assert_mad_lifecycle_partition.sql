-- depends_on: {{ ref('fact_driver_activity_daily') }}
-- depends_on: {{ ref('dim_drivers') }}
-- Check configured semantic formulas against independent per-driver lifecycle membership.
-- Fixtures use relative days so the boundary cases are portable across warehouses.
{% if execute %}
    {% set metric_prefix = 'metric.kwwhat.' %}
    {% set bindings = [
        ('mad', 'active', 'active_drivers_30d'),
        ('mad_new', 'new_entrants', 'new_drivers'),
        ('mad_retained', 'retained', 'retained_drivers_30d'),
        ('mad_resurrected', 'resurrected', 'resurrected_drivers_30d'),
        ('mad_churned', 'churned', 'churned_drivers_30d')
    ] %}
    {% for metric_name, expected_alias, expected_input in bindings %}
        {% set metric = graph.metrics[metric_prefix ~ metric_name] %}
        {% if metric.type_params.metrics | length != 1 %}
            {{ exceptions.raise_compiler_error(metric_name ~ ' must preserve its single input metric.') }}
        {% endif %}
        {% set input = metric.type_params.metrics[0] %}
        {% if input.name != expected_input or input.alias != expected_alias or input.offset_window or input.filter %}
            {{ exceptions.raise_compiler_error(metric_name ~ ' must preserve its unfiltered, unshifted lifecycle input.') }}
        {% endif %}
    {% endfor %}
    {% set stale = graph.metrics[metric_prefix ~ 'mad_stale'] %}
    {% set stale_inputs = stale.type_params.metrics %}
    {% if stale_inputs | length != 2
        or stale_inputs[0].name != 'drivers_observed_to_date'
        or stale_inputs[0].alias != 'known_to_date'
        or stale_inputs[1].name != 'driver_activity_union_31d'
        or stale_inputs[1].alias != 'union_active' %}
        {{ exceptions.raise_compiler_error('mad_stale must subtract the 31-day union from the historical observed population.') }}
    {% endif %}
    {% set population = graph.metrics[metric_prefix ~ 'drivers_observed_to_date'] %}
    {% if population.type != 'cumulative'
        or population.type_params.measure.name != 'known_drivers_count'
        or population.type_params.cumulative_type_params.window
        or population.type_params.cumulative_type_params.grain_to_date %}
        {{ exceptions.raise_compiler_error('The lifecycle population must accumulate first-seen drivers over all history.') }}
    {% endif %}
    {% set retained_expr = graph.metrics[metric_prefix ~ 'retained_drivers_30d'].type_params.expr %}
    {% set resurrected_expr = graph.metrics[metric_prefix ~ 'resurrected_drivers_30d'].type_params.expr %}
    {% set churned_expr = graph.metrics[metric_prefix ~ 'churned_drivers_30d'].type_params.expr %}
    {% set mad_expr = graph.metrics[metric_prefix ~ 'mad'].type_params.expr %}
    {% set new_expr = graph.metrics[metric_prefix ~ 'mad_new'].type_params.expr %}
    {% set mad_retained_expr = graph.metrics[metric_prefix ~ 'mad_retained'].type_params.expr %}
    {% set mad_resurrected_expr = graph.metrics[metric_prefix ~ 'mad_resurrected'].type_params.expr %}
    {% set mad_churned_expr = graph.metrics[metric_prefix ~ 'mad_churned'].type_params.expr %}
    {% set stale_expr = stale.type_params.expr %}
{% else %}
    {% set retained_expr = '0' %}
    {% set resurrected_expr = '0' %}
    {% set churned_expr = '0' %}
    {% set mad_expr = '0' %}
    {% set new_expr = '0' %}
    {% set mad_retained_expr = '0' %}
    {% set mad_resurrected_expr = '0' %}
    {% set mad_churned_expr = '0' %}
    {% set stale_expr = '0' %}
{% endif %}

with reporting_days as (
    select -101 as as_of_day
    union all select 0
    union all select 1
    union all select 29
    union all select 30
    union all select 31
    union all select 32
    union all select 63
    union all select 93
    union all select 94
),

activity as (
    select 'new' as driver_id, 0 as activity_day
    union all select 'retained_without_today', -1
    union all select 'repeat', -2
    union all select 'repeat', 0
    union all select 'repeat', 0
    union all select 'recent_acquisition', -29
    union all select 'boundary_return', -30
    union all select 'boundary_return', 0
    union all select 'resurrected', -31
    union all select 'resurrected', 0
    union all select 'churned', -30
    union all select 'stale', -31
    union all select 'ancient_stale', -100
    union all select 'future', 63
),

per_driver as (
    select
        d.as_of_day,
        a.driver_id,
        min(a.activity_day) as first_day,
        max(case when a.activity_day between d.as_of_day - 29 and d.as_of_day then 1 else 0 end) as in_current,
        max(case when a.activity_day between d.as_of_day - 30 and d.as_of_day - 1 then 1 else 0 end) as in_previous,
    from reporting_days as d
    cross join activity as a
    group by d.as_of_day, a.driver_id
),

classified as (
    select
        as_of_day,
        driver_id,
        in_current,
        in_previous,
        case when first_day <= as_of_day then 1 else 0 end as is_observed,
        case when first_day = as_of_day then 1 else 0 end as is_new,
        case when in_current = 1 and in_previous = 1 then 1 else 0 end as is_retained,
        case when in_current = 1 and in_previous = 0 and first_day < as_of_day then 1 else 0 end as is_resurrected,
        case when in_current = 0 and in_previous = 1 then 1 else 0 end as is_churned,
        case when first_day <= as_of_day and in_current = 0 and in_previous = 0 then 1 else 0 end as is_stale,
    from per_driver
),

set_counts as (
    select
        as_of_day,
        sum(is_observed) as known_to_date,
        sum(in_current) as current_active,
        sum(in_previous) as previous_active,
        sum(case when in_current = 1 or in_previous = 1 then 1 else 0 end) as union_active,
        sum(is_new) as new_entrants,
        sum(is_retained) as expected_retained,
        sum(is_resurrected) as expected_resurrected,
        sum(is_churned) as expected_churned,
        sum(is_stale) as expected_stale,
        sum(case when is_new + is_retained + is_resurrected + is_churned + is_stale != is_observed then 1 else 0 end) as partition_violations,
    from classified
    group by as_of_day
),

retained_results as (
    select
        as_of_day,
        known_to_date,
        current_active,
        previous_active,
        union_active,
        new_entrants,
        expected_retained,
        expected_resurrected,
        expected_churned,
        expected_stale,
        partition_violations,
        {{ retained_expr }} as retained,
    from set_counts
),

accounting_results as (
    select
        as_of_day,
        known_to_date,
        current_active as active,
        previous_active,
        union_active,
        new_entrants,
        retained,
        expected_retained,
        expected_resurrected,
        expected_churned,
        expected_stale,
        partition_violations,
        {{ resurrected_expr }} as resurrected,
        {{ churned_expr }} as churned,
    from retained_results
),

results as (
    select
        as_of_day,
        known_to_date,
        active,
        previous_active,
        new_entrants,
        expected_retained,
        expected_resurrected,
        expected_churned,
        expected_stale,
        partition_violations,
        {{ mad_expr }} as mad,
        {{ new_expr }} as mad_new,
        {{ mad_retained_expr }} as mad_retained,
        {{ mad_resurrected_expr }} as mad_resurrected,
        {{ mad_churned_expr }} as mad_churned,
        {{ stale_expr }} as mad_stale,
    from accounting_results
)

select
    as_of_day,
    mad,
    mad_new,
    mad_retained,
    mad_resurrected,
    mad_churned,
    mad_stale,
    known_to_date,
from results
where mad is null
    or mad_new is null
    or mad_retained is null
    or mad_resurrected is null
    or mad_churned is null
    or mad_stale is null
    or mad_new < 0
    or mad_retained < 0
    or mad_resurrected < 0
    or mad_churned < 0
    or mad_stale < 0
    or partition_violations != 0
    or mad != active
    or mad_new != new_entrants
    or mad_retained != expected_retained
    or mad_resurrected != expected_resurrected
    or mad_churned != expected_churned
    or mad_stale != expected_stale
    or mad != mad_new + mad_retained + mad_resurrected
    or known_to_date != mad_new + mad_retained + mad_resurrected + mad_churned + mad_stale
    or mad - previous_active != mad_new + mad_resurrected - mad_churned
