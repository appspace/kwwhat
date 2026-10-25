# 0008. Warehouse-resident checkpoints for incremental processing

- Status: Proposed
- Date: 2026-10-25
- Related: `macros/incremental_checkpoint.sql`, `macros/incremental_date_range.sql`, incremental models

## Context

Incremental models process bounded windows and commonly use `max(incremental_ts)` from their own output as the next lower boundary. A window with no qualifying rows writes nothing, so that target-derived boundary cannot advance. Later data beyond the empty window is then never reached. Model output is therefore not a reliable store of processing progress.

The project must run on dbt Platform and self-hosted dbt, use disposable runners, and remain compatible with Snowflake and BigQuery. The scheduled production job currently runs full refresh, allowing the checkpoint design to be introduced before incremental cutover.

## Decision

Store pipeline progress in a warehouse checkpoint relation, separate from business-model output.

Checkpoint mode is explicitly enabled per invocation. Within one `dbt build` or `dbt run` invocation:

1. An `on-run-start` hook claims a bounded window and records the dbt `invocation_id` with a lease.
2. Every incremental model reads that same pending window.
3. An `on-run-end` hook finalizes the window only when all selected resources complete without failure or error.
4. A failed run leaves the window pending. After its lease expires, a later invocation reclaims the same boundaries.

Checkpoint rows are isolated by their target relation, `target.name`, and checkpoint name. `incremental_ts` remains row metadata and is not authoritative pipeline state while checkpoint mode is enabled.

The initial rollout is opt-in. Production remains full refresh and CI keeps legacy behavior until their commands are intentionally changed.

## Alternatives considered

- **Keep target-derived watermarks.** Empty windows cannot advance, which is the failure being corrected.
- **Insert sentinel rows into every model.** This pollutes business grains and complicates tests and consumers.
- **Use a platform-only orchestration checkpoint.** This would not support self-hosted dbt or disposable runners consistently.
- **Run separate claim, build, and finalize commands.** Separate dbt invocations have different `invocation_id` values and require an external claim token. Lifecycle hooks keep ownership and result inspection in one invocation.
- **Advance checkpoints independently per model.** Partial DAG failures could leave upstream and downstream models on different windows.

## Consequences

- Empty windows advance after a successful DAG execution.
- The complete selected incremental pipeline advances in lockstep.
- Incremental replays must be idempotent because a crash can occur after model writes but before finalization.
- Overlapping checkpoint-enabled builds are rejected while a lease is active.
- Full refresh bypasses checkpoint behavior.
- Ad hoc partial selections must not enable the production checkpoint because successful finalization would claim the window for resources that were not selected.
- Checkpoint DDL and DML must remain portable through dispatched macros where adapters differ.
- Production and CI job commands require an explicit cutover after validation.
