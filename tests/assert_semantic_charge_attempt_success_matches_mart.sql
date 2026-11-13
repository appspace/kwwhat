-- depends_on: {{ ref('fact_charge_attempts') }}
-- A semantic dimension must respect the mart's configured success decision.
-- Exercise outcomes from both higher and lower thresholds without changing project vars.
{% if execute %}
    {% set attempt_model = graph.semantic_models['semantic_model.kwwhat.charge_attempts'] %}
    {% set success_dimensions = attempt_model.dimensions | selectattr('name', 'equalto', 'is_successful') | list %}
    {% set success_expr = success_dimensions[0].expr or 'is_successful' %}
{% else %}
    {% set success_expr = 'is_successful' %}
{% endif %}

with fixtures as (
    select
        'higher_threshold' as scenario,
        'transaction_1' as transaction_id,
        'Available' as next_status,
        'Local' as transaction_stop_reason,
        0.15 as energy_transferred_kwh,
        false as is_successful,
    union all
    select
        'lower_threshold' as scenario,
        'transaction_2' as transaction_id,
        'Available' as next_status,
        'Local' as transaction_stop_reason,
        0.05 as energy_transferred_kwh,
        true as is_successful,
),

results as (
    select
        scenario,
        is_successful as mart_is_successful,
        ({{ success_expr }}) as semantic_is_successful,
    from fixtures
)

select
    scenario,
    mart_is_successful,
    semantic_is_successful,
from results
where semantic_is_successful is null
    or semantic_is_successful != mart_is_successful
