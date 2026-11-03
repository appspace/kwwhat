# 0013. Stop-based driver lifecycle activity

- Status: Proposed
- Date: 2026-11-03
- Related: ADRs 0008, 0010, 0011, 0012; int_driver_aggregates, dim_drivers, fact_driver_activity_daily

## Context

The metric owner defines selected-period active drivers as credentials with at least
one charge attempt stopping in [S, E). The owner also requested first/last seen and
published driver lifecycle metrics use the same stop-time basis. Before this migration,
int_driver_aggregates and fact_driver_activity_daily used attempt starts, which could
place acquisitions and activity on different dates from stopped attempts, especially
across midnight. Both models now use charge_attempt_stop_ts; daily activity groups
stopped attempts by the stop's calendar date.


## Decision

Use non-null `fact_charge_attempts.charge_attempt_stop_ts` as driver lifecycle activity,
regardless of success. First/last seen become the earliest/latest observed stop per
credential; authorization attributes follow stop ordering with existing min_by/max_by
tie behavior. Open attempts contribute no lifecycle timestamps or driver-days. Retain
the existing unknown sentinel mapping and known-credential exclusions.

Daily activity uses the stop's calendar date without timezone conversion. Preserve row
grains, surrogate-key formulas, output columns, and rolling 7/30-day accounting formulas.
MAD and related metrics retain their names and daily window semantics, with their
underlying activity and acquisition histories now consistently stop-based. Attempt-level
semantic measures retain their existing start-time attribution; visits retain visit-end
attribution and authoritative success definitions.

Selected-period activity and the fixed pre-period 30-day lookup both use stop times.
New means first-ever observed stop in [S, E); retained/resurrected require first stop
before S and respectively presence/absence of stops in [S minus 30 days, S). A first
attempt starting before S and stopping inside the period is New. Freeze cohorts at S.
This revises the start-time portions of Proposed ADRs 0010 and 0013, and clarifies the
activity/first-seen basis in Proposed ADRs 0011 and 0012. Their window arithmetic remains.

Keep model-local bounded processing and strict-lower/inclusive-upper updated_ts filters
under accepted ADR 0008. Null-to-stop and earlier late-stop updates are handled when
updated_ts enters a processing window. Open-only windows emit no sentinel rows and cannot
advance the local watermark; retain ADR 0008's investigation and recovery policy.

## Alternatives considered

- Change only dim_drivers: acquisition dates would diverge from daily activity and could
  break growth accounting, including the new/retained/resurrected partition.
- Compute first stop from lifetime attempts in every Chat BI query: duplicates history
  logic and increases repeated scan cost.
- Add parallel start/stop lifecycle metrics: the owner selected one consistent stop-based
  definition for all driver lifecycle metrics.

## Consequences

This is a semantic migration even though column names/types and keys remain stable.
Consumers must be told that first_seen_ts no longer means first attempt start and that
open-only drivers are absent until a stop is observed. Historical lifecycle dates and
authorization ordering can change. Current last_seen_ts still cannot classify a driver's
historical pre-period activity.

Rebuild int_driver_aggregates and fact_driver_activity_daily together from the same
available attempt history, then refresh dim_drivers. A normal merge preserves old start
minima and obsolete start-date presence rows. Scope full refresh to those models, not
unrelated incrementals. Check source size, start_processing_date, update coverage, and
incremental_window first. If history exceeds one bounded window, repeat normal builds
until coverage catches up; only then expose aligned metrics. Retained source history
limits recoverable first-ever activity. Production needs its own coordinated rollout.

Stop retractions, stop-date moves, driver reassignments, and corrections that move an
existing min/max inward require explicit reconciliation or rebuild. Accumulating merge
logic does not remove obsolete presence or recompute history after retraction.

For live reporting, the expected processed cutoff is clock minus 35 minutes when the
processing SLA is met. Preserve literal requested bounds and label their recent portion
provisional; shift only for explicitly requested fully processed periods. This SLA is
not evidence of visit finalization. The 14-day demo cannot establish complete 30-day
prehistory. Snowflake validation does not certify BigQuery or DuckDB runtime behavior.
