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

Incremental models do not read their own targets to derive runtime processing boundaries. When checkpoint mode is disabled for a run, build, compile, full refresh, or isolated CI context, `incremental_date_range` returns a deterministic bounded range from `start_processing_date` to `least(start + incremental_window, newest source row)`, the same rule the claim uses, so a window never ends past the data. Models do not pass their own caps, and the start is never moved to the first source row: every model, with or without the checkpoint, uses the same window. That fallback does not advance and must not be used as production pipeline state. Incremental unit tests set their window explicitly through `start_processing_date` because dbt's unit-test harness does not execute lifecycle hooks.

No model carries a processing stamp. The former `incremental_ts` column is removed everywhere, along with the upstream caps that read `max(incremental_ts)` from parent models: within one invocation every model processes the same window in DAG order, so the caps protected nothing, and they cut the tail off full refreshes (an upstream model's last row is not how far it processed). Downstream models read changed upstream rows by business timestamps that always fall inside the window that wrote them:

- `updated_ts`, the latest source event reflected in a row (`int_status_changes`, `int_connector_preparing`, `int_transactions`, and `fact_charge_attempts`, which takes the later of its two inputs).
- `to_ts` for outages: a new, extended or closed outage ends inside the window that wrote it.
- Open-record reconciliation reads still-open rows directly (`int_faulted_outages` reads every status with no `next_status`), instead of relying on the upstream model writing them again with a new stamp.

An ongoing outage ends at the last OCPP log received in the window, computed by the outage model itself.

Checkpoint rows are isolated by their target relation, `project_name`, `target.name`, and configured checkpoint name. The project name is included in the stored checkpoint key.

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
- A full refresh and a checkpoint-driven incremental rebuild read the same rows, so they can be compared directly: no column legitimately differs between them.
- Overlapping checkpoint-enabled builds are rejected while a lease is active.
- Full refresh bypasses checkpoint behavior and starts from `start_processing_date`.
- Disabled checkpoint mode is deterministic and non-advancing; it is suitable for compilation, tests, and isolated validation, not production scheduling.
- Ad hoc partial selections must not enable the production checkpoint because successful finalization would advance the shared window for resources that were not selected.
- Checkpoint DDL and DML must remain portable through dispatched macros where adapters differ.
- Production requires an explicit checkpoint-enabled job command. CI remains checkpoint-disabled unless it receives an isolated initialization and selection strategy.
