# 0002. Port grain for reliability and utilisation metrics

- Status: Accepted
- Date: 2026-10-15 (backfilled; decision predates this record)
- Related: `dim_ports`, `fact_uptime`, `fact_downtime_daily`, `fact_charge_attempts`

## Context

OCPP 1.6 reports status per connector, but a driver experiences availability per Port (EVSE):
the unit that can charge one vehicle at a time. A Port can have several mutually exclusive
connectors (e.g. CCS and CHAdeMO), and a Charger can have several Ports.

## Decision

Track uptime, downtime and charge attempts at Port grain (`charger_id + port_id`).
A Port counts as FAULTED only when every connector on it reports Faulted.

## Alternatives considered

- **Charger grain.** Hides partial failures: a two-port charger with one dead port would look
  fully up or fully down.
- **Connector grain.** Overcounts capacity and downtime: an unused CHAdeMO connector faulting
  does not stop the Port from serving CCS vehicles.

## Consequences

- Metrics answer "how many vehicles could charge here?" directly.
- OCPP 1.6 events carry `connector_id`, not `port_id`, so the port must be resolved upstream
  (see [0003](0003-facts-generate-dimension-keys-in-place.md)).
- Charger- and location-level metrics are rollups of port-level facts, not separate logic.
