-- A port's connectors all share the same OEM and therefore the same vendor fault-code scheme
-- (vendorId, carried as taxonomy). More than one distinct taxonomy reported while faulted on
-- the same port signals a data quality issue, not a legitimate multi-vendor port - it would
-- make int_faulted_outages.latest_taxonomy depend on which connector faulted last.

select
    charger_id,
    port_id,
    count(distinct taxonomy) as taxonomy_count
from {{ ref('int_status_changes') }}
where status = 'Faulted'
    and taxonomy is not null
group by charger_id, port_id
having count(distinct taxonomy) > 1
