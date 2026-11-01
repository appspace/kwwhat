# 0008. Model-local watermarks for incremental processing

- Status: Accepted
- Date: 2026-10-25
- Related: `macros/incremental_date_range.sql`, incremental models

## Context

Incremental models use bounded windows so that production runs process a manageable amount of source data. Each model derives its next lower boundary from `max(_incremental_ts)` in that model's output. The leading underscore identifies the watermark as a technical field, not a business attribute.

An output-derived watermark does not advance when a model writes no qualifying rows. This is expected for outage models because a healthy period can contain no outages. In a functional, reasonably sized EV charging network, every other incremental model is expected to receive and emit qualifying data between scheduled runs. A non-outage model that does not advance therefore indicates a broader ingestion or network failure rather than a normal empty business window.

We explored storing pipeline progress in a shared warehouse checkpoint. An `on-run-start` hook claimed one bounded window for the full DAG, and an `on-run-end` hook finalized it only after a successful run. A failed invocation preserved the pending window for an exact retry.

Exact retry required every incremental model to be idempotent. That was straightforward for replacement-style models but difficult for cumulative aggregates such as `int_meter_values` and `fact_interval_data`, where replaying the same source rows adds their counts and weighted averages twice. Making those models replay-safe required reintroducing target-local applied-through watermarks alongside the shared checkpoint. The resulting hybrid had two state systems, two kinds of recovery behavior, and roughly doubled the conceptual and operational complexity of incremental processing.

## Decision

Retain model-local output watermarks as the incremental progress mechanism for normal models. Do not introduce a shared warehouse pipeline checkpoint.

This decision relies on the production invariant that every non-outage incremental model advances between scheduled runs. If one does not, treat that as an ingestion or operational failure and recover with a retry, explicit model-watermark reset, backfill, or full refresh as appropriate.

Outage models are the explicit sparse-output exception. They may legitimately write no rows during a healthy window. During incremental runs, both outage models use the latest two distinct `_incremental_ts` values from dense `int_status_changes` as their range boundaries. The upper boundary is still capped by the configured `incremental_window` and newest source event. Their downstream sparse consumer, `fact_downtime_daily`, uses the same dense range. The outage models retain their boundary and open-record reconciliation so an outage that spans windows can be extended or closed when new source events arrive.

In particular:

- `int_faulted_outages` continues to read changed statuses plus still-open statuses.
- `int_offline_outages` continues to read the prior boundary outage and merge it with the next observed period.
- `fact_downtime_daily` processes changed outage rows using the same dense status-change range rather than an outage model's sparse output watermark.

## Alternatives considered

- **Warehouse-resident pipeline checkpoint.** This correctly advances empty windows and coordinates the whole DAG, but failed runs must replay the same window. Cumulative models are not naturally replay-idempotent, so this option required model-local applied-through state in addition to pipeline state. The hybrid was rejected because it doubled state and recovery complexity.
- **Per-model completion records inside the shared checkpoint.** This could skip models that committed before a later DAG failure, but it adds model lifecycle bookkeeping, partial-run semantics, and another recovery surface.
- **Sentinel output rows for empty windows.** This would advance model-local watermarks but pollutes business grains and complicates tests and consumers.
- **Independent warehouse checkpoint rows per model.** This moves the existing model-local state into metadata without reducing the number of watermarks or simplifying partial failures.

## Consequences

- Incremental progress remains local to each model and easy to inspect from model output.
- Cumulative models do not need replay-window markers or a second applied-through watermark.
- Production scheduling does not need checkpoint claim, lease, and finalization hooks.
- A normal empty window in a non-outage model can stall that model. The project accepts this risk because it violates the production traffic assumption and should trigger operational investigation.
- Outage consumers must remain independent of outage-output watermark caps.
- Tests must cover an outage-free window followed by a later outage, plus open outages that continue or close across window boundaries.
- Ad hoc partial runs preserve their existing per-model behavior and cannot advance unrelated models.
