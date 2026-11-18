# 0012. Network-unique port and connector ids

- Status: Proposed
- Date: 2026-11-18
- Related: #195, `macros/network_scoped_id.sql`, `stg_ports`, `stg_connectors`, `int_ocpp_logs`, `dim_ports`, `dim_connectors`

## Context

OCPP numbers ports and connectors within a charger. The raw `ports` source has port numbers `1`, `2` on every
two-port charger. OCPP 1.6 `connectorId` is numbered per charger, not per port: port 2 of CH-002 has
connectors 3 and 4. We carried these raw numbers as `port_id` and `connector_id`, so neither was unique across
the network. Only (`charger_id`, `port_id`) and the hashed `port_key` identified a port.

An AI analytics agent asked "Why were there zero charging visits from Oct 15 to Oct 19, 2025?" counted ports
with `count(distinct port_id)` in 6 of 8 answers. That query returned 2 for a network of 4 ports and led to
wrong conclusions about which chargers were offline. The agents saw column names and values but rarely read
column docs, so better descriptions alone would not have fixed it.

[0002](0002-port-grain-for-reliability-metrics.md) (port grain) and
[0003](0003-facts-generate-dimension-keys-in-place.md) (keys generated in place, natural keys resolved in
intermediate) are unchanged. This record changes only the values of the natural ids they refer to.

## Decision

- `port_id` and `connector_id` are network-unique in every layer: `'<charger_id>-<number>'`, e.g. port
  `CH-002-1`, connector `CH-002-3`. Connectors are prefixed by the charger (not the port) because OCPP
  `connectorId` is unique per charger.
- The raw connector number stays available as integer `connector_number` (the OCPP `connectorId`) on
  `stg_connectors`, `int_connectors` and `dim_connectors`, to tie a connector back to raw payloads and field
  reports. There is no `port_number`: the port number has no protocol meaning in OCPP 1.6, is already inside
  `port_id`, and another readable non-unique column would invite the same `count(distinct ...)` mistake.
- The ids are built in staging for reference data and in `int_ocpp_logs` (and `fact_interval_data`, which reads
  `connectorId` from the payload itself) for events, always through the `network_scoped_id` macro so the
  formula exists in one place. Connector 0 (the charger as a whole) becomes `'<charger_id>-0'`.
- Raw source columns keep their OCPP names and values.
- Hashes no longer include `charger_id` next to a network-unique id: `port_key` hashes `port_id`,
  `connector_key` hashes `connector_id`, and the same applies to `uptime_id`, `outage_id`,
  `charge_attempt_id`, `interval_data_id`, `meter_value_id` and the visit port keys. `visit_id` keeps
  `first_charger_id`, because `first_port_id` is null when the port can't be resolved.
- The generic test `scoped_by_charger` checks every `port_id` and `connector_id` column.

## Alternatives considered

- **Better column descriptions only.** The failing answers never read the docs; names and values are what every
  query sees.
- **Keep raw numbers in `port_id` and add a new global column (e.g. `port_code`).** The obvious query,
  `count(distinct port_id)`, would still be wrong.
- **Prefix connectors by port (`CH-002-2-3`).** Longer, and it hides that OCPP `connectorId` is already unique
  per charger, which is how events identify a connector.
- **Use the readable id as `port_key`.** Out of scope for #195; possible follow-up.

## Consequences

- `count(distinct port_id)` and `count(distinct connector_id)` count ports and connectors correctly, and results
  read "CH-002-1 offline" rather than "port 1 offline".
- Joins on (`charger_id`, `port_id`) still work and return the same rows; `port_id` alone is now also a valid key.
- `port_id` and `connector_id` no longer equal OCPP raw values. Code comparing them to a raw number (e.g.
  connector `'0'`) must use `network_scoped_id` or `connector_number`.
- A hash over a network-unique id must only drop `charger_id` where that id is never null (tested `not_null`);
  otherwise rows from different chargers with a null id would collide.
- Rolling this out needs a `--full-refresh`: incremental unique keys include `connector_id` or `port_id`, and
  every surrogate key listed above changes value, so anything downstream that stores them must rebuild.
