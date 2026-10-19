# 0007. Rated power as the denominator for energy-based utilisation

- Status: Accepted
- Date: 2026-10-01
- Related: #139, `dim_ports.max_power_kw`, `dim_connectors.max_power_kw`, `migrations/002_add_max_power.sql`

## Context

Time-based utilisation treats a port that delivered 7 kW for an hour the same as one that
delivered 150 kW. Energy-based utilisation (energy delivered / energy the hardware could have
delivered) needs a rated power for each Port and Connector, which OCPP 1.6 does not report.

## Decision

- Store `max_power_kw` on ports and connectors from hardware reference data (seeds and CMMS),
  as `number(10, 2)` so AC ratings like 7.4 kW are not truncated.
- Port `max_power_kw` is the physical ceiling of the Port: the max across its connectors, not
  the sum, because connectors on a Port are mutually exclusive.
- Port-level utilisation uses the Port rating; connector-level utilisation uses the Connector
  rating.

## Alternatives considered

- **Sum connector ratings for the Port.** Overstates capacity: a 50 kW CHAdeMO plus 150 kW CCS
  Port cannot deliver 200 kW.
- **Infer capacity from observed peak power.** Unreliable for rarely used or throttled hardware.

## Consequences

- A session on a lower-rated connector legitimately shows lower Port utilisation.
- Utilisation accuracy depends on reference data quality; missing ratings must be filled from
  the hardware registry.
