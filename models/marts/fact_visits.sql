{{
  config(
    materialized='table',
    cluster_by="visit_start_ts"
  )
}}

select
    v.visit_id,
    {{ dbt_utils.generate_surrogate_key(['v.location_id']) }} as location_key,
    {{ dbt_utils.generate_surrogate_key(["coalesce(v.id_tag, 'UNKNOWN')"]) }} as driver_key,
    {{ dbt_utils.generate_surrogate_key(['v.first_charger_id', 'v.first_port_id']) }} as first_port_key,
    {{ dbt_utils.generate_surrogate_key(['v.last_charger_id', 'v.last_port_id']) }} as last_port_key,
    v.location_id,
    v.id_tag,
    v.visit_start_ts,
    v.visit_end_ts,
    v.charge_attempt_count,
    v.total_energy_transferred_kwh,
    v.first_charge_attempt_id,
    v.last_charge_attempt_id,
    v.first_charger_id,
    v.last_charger_id,
    v.first_port_id,
    v.last_port_id,
    v.is_successful,
    v.last_error_code,
    v._grouping_key,
    v.visit_duration_minutes,
    v.incremental_ts
from {{ ref('int_visits') }} as v
