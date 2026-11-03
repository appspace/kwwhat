# 0013. Stop-based driver lifecycle activity

- Status: Proposed
- Date: 2026-11-03
- Related: ADRs 0003, 0008; int_driver_aggregates, dim_drivers

## Context

The metric owner defines driver activity as a credential having at least one charge
attempt that stopped. The owner also asked that first/last seen and the published driver
lifecycle attributes use the same stop-time basis. Before this change,
int_driver_aggregates used attempt starts, so a driver's acquisition date could fall on a
different date than the stopped attempt that established it, especially across midnight.

## Decision

Use non-null `fact_charge_attempts.charge_attempt_stop_ts` as driver lifecycle activity,
regardless of success. First/last seen become the earliest/latest observed stop per
credential; authorization attributes follow stop ordering with existing min_by/max_by
tie behavior. Open attempts contribute no lifecycle timestamps. Retain the existing
unknown sentinel mapping and known-credential exclusions.

Preserve row grain, surrogate-key formulas and output columns of int_driver_aggregates
and dim_drivers. Attempt-level semantic measures retain their existing start-time
attribution; visits retain visit-end attribution and authoritative success definitions.

Keep model-local bounded processing and strict-lower/inclusive-upper updated_ts filters
under accepted ADR 0008. Null-to-stop and earlier late-stop updates are handled when
updated_ts enters a processing window. Open-only windows emit no sentinel rows and cannot
advance the local watermark; retain ADR 0008's investigation and recovery policy.

## Alternatives considered

- Change only dim_drivers: the dimension reads int_driver_aggregates, so the basis has
  to change where the history is accumulated.
- Compute first stop from lifetime attempts in every query: duplicates history logic and
  increases repeated scan cost.
- Add parallel start/stop lifecycle attributes: the owner selected one consistent
  stop-based definition for all driver lifecycle attributes.

## Consequences

This is a semantic migration even though column names/types and keys remain stable.
Consumers must be told that first_seen_ts no longer means first attempt start and that
open-only drivers are absent until a stop is observed. Historical lifecycle dates and
authorization ordering can change.

Rebuild int_driver_aggregates from the available attempt history, then refresh
dim_drivers. A normal merge preserves old start minima. Scope full refresh to those
models, not unrelated incrementals. Check source size, start_processing_date, update
coverage, and incremental_window first. If history exceeds one bounded window, repeat
normal builds until coverage catches up. Retained source history limits recoverable
first-ever activity. Production needs its own coordinated rollout.

Stop retractions, driver reassignments, and corrections that move an existing min/max
inward require explicit reconciliation or rebuild. Accumulating merge logic does not
recompute history after retraction.
