select
    v.visit_id,
    v.charge_attempt_count,
    coalesce(b.bridge_attempt_count, 0) as bridge_attempt_count
from {{ ref('fact_visits') }} as v
left join (
    select
        visit_id,
        count(*) as bridge_attempt_count
    from {{ ref('bridge_visit_charge_attempts') }}
    group by visit_id
) as b
    on v.visit_id = b.visit_id
where v.charge_attempt_count != coalesce(b.bridge_attempt_count, 0)
