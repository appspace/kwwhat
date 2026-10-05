{{ config(severity='warn') }}

-- Outages are only built for chargers and ports that have a row in int_ports, so an outage whose charger or port
-- has no reference row yet (OCPP logs arrived before the ports data) is dropped and downtime is under-reported.
-- FAULTED is checked at the source, int_status_changes: int_faulted_outages needs int_ports to count a port's
-- connectors, so it never holds the dropped ones. A Faulted connector with no port_id is not in int_connectors.
-- Connector 0 reports for the whole charger and has no port_id, so it is checked against the charger's ports.
-- OFFLINE outages fan out to a charger's ports in fact_downtime_daily, so int_offline_outages is checked directly.

select distinct
    'FAULTED' as downtime_type,
    sc.charger_id,
    sc.port_id,
    sc.ingested_ts as from_ts
from {{ ref('int_status_changes') }} as sc
left join {{ ref('int_ports') }} as p
    on sc.charger_id = p.charger_id
    and sc.port_id = p.port_id
where sc.status = 'Faulted'
    and sc.connector_id != '0'
    and p.port_id is null

union all

select distinct
    'FAULTED' as downtime_type,
    sc.charger_id,
    cast(null as {{ dbt.type_string() }}) as port_id,
    sc.ingested_ts as from_ts
from {{ ref('int_status_changes') }} as sc
left join {{ ref('int_ports') }} as p
    on sc.charger_id = p.charger_id
where sc.status = 'Faulted'
    and sc.connector_id = '0'
    and p.charger_id is null

union all

select distinct
    'OFFLINE' as downtime_type,
    o.charger_id,
    cast(null as {{ dbt.type_string() }}) as port_id,
    o.from_ts
from {{ ref('int_offline_outages') }} as o
left join {{ ref('int_ports') }} as p
    on o.charger_id = p.charger_id
where p.charger_id is null
