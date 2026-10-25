# Incremental pipeline checkpoint plan

## Goal

Prevent bounded incremental processing from stalling when a window contains no qualifying business rows. Processing progress must advance independently from `max(incremental_ts)` in model output.

## Current state

- Twelve models are incremental.
- Most use `max(incremental_ts)` from `{{ this }}` as the next lower boundary.
- An empty bounded window writes no rows, so that boundary does not advance.
- The scheduled production job currently runs `dbt build --full-refresh --exclude "test_type:unit"`, so production is not yet exposed to the stall.
- The CI job runs `dbt build --select state:modified+` and must remain unaffected until checkpoint mode is explicitly enabled.

## Decision

Use a warehouse-resident pipeline checkpoint managed by dbt lifecycle hooks.

- `on-run-start` claims one deterministic processing window.
- Every incremental model in the invocation reads the same pending window.
- `on-run-end` finalizes the window only when all selected resources succeed.
- A failed or crashed run leaves the window pending for replay.
- A lease prevents overlapping invocations from claiming the same pipeline concurrently.
- Checkpoint mode is opt-in during rollout.

The checkpoint is isolated by target database, target schema, target name, and checkpoint name. Disposable runners and self-hosted containers are supported because state lives in the warehouse.

## Implementation

### Checkpoint relation

The target schema contains `_kwwhat_incremental_checkpoint` with:

- `checkpoint_name`
- `target_name`
- `status`
- `completed_through_ts`
- `pending_from_ts`
- `pending_to_ts`
- `claim_id`
- `claimed_at`
- `lease_expires_at`
- `updated_at`

### Claim behavior

1. Create the checkpoint relation if needed.
2. Initialize from `start_processing_date` when no row exists.
3. Claim the next bounded window using the maximum timestamp in `stg_ocpp_logs` as the source cap.
4. Reclaim an expired pending window without changing its boundaries.
5. Reject an overlapping run while another lease is active.

### Finalize behavior

1. Inspect the `on-run-end` results.
2. Leave the checkpoint pending if any resource failed or errored.
3. On success, set `completed_through_ts = pending_to_ts` and clear the pending state.
4. Require the same dbt `invocation_id` that claimed the window.

### Model behavior

When `incremental_checkpoint_enabled: true`, `incremental_date_range` reads the pending checkpoint instead of deriving its lower boundary from `{{ this }}`. Existing model-specific lookbacks and state reconciliation remain in place.

`incremental_ts` remains row-level processing metadata. It is no longer authoritative pipeline state in checkpoint mode.

## Validation

- Parse and compile with checkpoint mode disabled.
- Initialize a development checkpoint after a successful full refresh.
- Build the complete incremental DAG with checkpoint mode enabled.
- Test an empty window followed by a populated window.
- Test build failure and retry of the same pending window.
- Replay one window and verify idempotency.
- Run full-refresh versus incremental parity on DuckDB.
- Validate Snowflake and BigQuery implementations before production cutover.

## Rollout

1. Merge the opt-in framework while production remains full refresh.
2. Initialize the production checkpoint to the raw source maximum included in a successful full refresh.
3. Change the production command to:

   ```text
   dbt build --exclude "test_type:unit" --vars '{incremental_checkpoint_enabled: true}'
   ```

4. Keep CI checkpoint mode disabled unless CI receives an isolated initialization flow.
5. Monitor pending/completed boundaries and replay behavior.
6. Remove legacy target-derived checkpoint paths only after production and self-hosted validation.

## Operational recovery

- Inspect state with `dbt run-operation show_incremental_checkpoint`.
- Initialize or reset state only with an explicit timestamp using `dbt run-operation initialize_incremental_checkpoint`.
- An active lease blocks overlap.
- An expired lease permits the next build to reclaim the same pending window.
- Never advance a checkpoint manually beyond data already represented by a successful full refresh or incremental build.

## Definition of done

- Empty windows advance without inserting sentinel business rows.
- Failed runs do not advance `completed_through_ts`.
- Retries use identical boundaries.
- Replays are idempotent.
- Full-refresh and incremental business output match.
- Dev, CI, production, and self-hosted targets do not share checkpoint state.
- Model headers and ADR 0008 describe the implemented behavior.
