# 0008. Warehouse-resident checkpoints for incremental processing

- Status: Proposed
- Date: 2026-10-25
- Related: `macros/incremental_checkpoint.sql`, `macros/incremental_date_range.sql`, incremental models

## Context

Incremental models previously used `max(incremental_ts)` from their own output as the next lower boundary. A window with no qualifying rows wrote nothing, so that target-derived boundary could not advance. Later data beyond the empty window was then never reached. Model output is therefore not a reliable store of processing progress.

The project must run on dbt Platform and self-hosted dbt, use disposable runners, and remain compatible with Snowflake and BigQuery. Production and CI also need explicit control over whether an invocation can advance shared pipeline state.

## Decision

Store pipeline progress in a warehouse checkpoint relation, separate from business-model output.

Checkpoint mode is explicitly enabled per invocation. Within one checkpoint-enabled `dbt build` or `dbt run` invocation:

1. An `on-run-start` hook claims a bounded window and records the dbt `invocation_id` with a lease.
2. Every incremental model reads that same pending window.
3. An `on-run-end` hook finalizes the window only when all selected resources complete without failure or error.
4. A failed run leaves the window pending. After its lease expires, a later invocation reclaims the same boundaries.

Incremental models do not read their own targets to derive runtime processing boundaries. When checkpoint mode is disabled for a run, build, compile, full refresh, or isolated CI context, `incremental_date_range` returns a deterministic bounded range beginning at `start_processing_date`, optionally constrained by source and upstream availability. That fallback does not advance and must not be used as production pipeline state. Incremental unit tests retain a test-only mocked-target boundary because dbt's unit-test harness does not execute lifecycle hooks.

Checkpoint rows are isolated by their target relation, `project_name`, `target.name`, and configured checkpoint name. The project name is included in the stored checkpoint key. `incremental_ts` remains row-level processing metadata and is never authoritative pipeline state.

## Alternatives considered

- **Keep target-derived watermarks.** Empty windows cannot advance, which is the failure being corrected.
- **Insert sentinel rows into every model.** This pollutes business grains and complicates tests and consumers.
- **Use a platform-only orchestration checkpoint.** This would not support self-hosted dbt or disposable runners consistently.
- **Run separate claim, build, and finalize commands.** Separate dbt invocations have different `invocation_id` values and require an external claim token. Lifecycle hooks keep ownership and result inspection in one invocation.
- **Advance checkpoints independently per model.** Partial DAG failures could leave upstream and downstream models on different windows.

## Consequences

- Empty windows advance after a successful checkpoint-enabled DAG execution.
- The complete selected incremental pipeline advances in lockstep.
- Incremental replays must be idempotent because a crash can occur after model writes but before finalization.
- Populated-window replay is currently blocked by nullable merge keys in `int_meter_values` and duplicate merge matches in `fact_charge_attempts`; production cutover requires resolving and revalidating this path.
- Overlapping checkpoint-enabled builds are rejected while a lease is active.
- Full refresh bypasses checkpoint behavior and starts from `start_processing_date`.
- Disabled checkpoint mode is deterministic and non-advancing; it is suitable for compilation, tests, and isolated validation, not production scheduling.
- Ad hoc partial selections must not enable the production checkpoint because successful finalization would advance the shared window for resources that were not selected.
- Checkpoint DDL and DML must remain portable through dispatched macros where adapters differ.
- Production requires an explicit checkpoint-enabled job command. CI remains checkpoint-disabled unless it receives an isolated initialization and selection strategy.
