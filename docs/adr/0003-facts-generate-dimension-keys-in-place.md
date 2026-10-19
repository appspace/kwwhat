# 0003. Facts generate dimension keys in place; natural keys resolve in intermediate

- Status: Accepted
- Date: 2026-10-15 (backfilled; decision predates this record)
- Related: `int_connectors`, `dim_ports`, `fact_*`

## Context

Facts need foreign keys such as `port_key` to join dimensions. Two problems: joining a `dim_`
table just to read its `_key` adds cost and a build dependency, and OCPP 1.6 events only carry
`charger_id + connector_id`, so `port_id` is missing on the raw event.

## Decision

- A `_key` is `dbt_utils.generate_surrogate_key(...)` over the dimension's natural key columns.
  Facts compute it from columns they already have, with the same formula as the owning dimension.
- Missing natural keys are resolved in the intermediate layer (e.g. `charger_id + connector_id`
  to `port_id` through `int_connectors`), so the id is on the row before it reaches a mart.
- Facts do not join `dim_` tables only to read a key. Joins for non-key columns are still fine.

## Alternatives considered

- **Join the dimension in every fact.** Simple, but duplicates resolution logic across facts and
  couples marts to OCPP 1.6 quirks.
- **Resolve `port_id` in each fact.** Same logic copied many times, drifting over time.

## Consequences

- Marts stay protocol-agnostic: an OCPP 2.x source carrying `port_id` natively needs no change
  in the marts.
- The hash formula is duplicated by design. If a dimension's key columns change, every fact
  computing that key must change in the same PR.
- Exception: `latest_error_code_key` is looked up by joining `dim_error_codes`, because that
  key hashes `error_code_name`, which is not on the outage row (see [0006](0006-unified-error-code-resolution.md)).
