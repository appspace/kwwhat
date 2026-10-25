# Incremental pipeline checkpoint plan

## Goal

Advance bounded incremental processing independently from business-model output, including windows that contain no qualifying rows.

## Current implementation

- A warehouse-resident checkpoint is claimed in `on-run-start` and finalized in `on-run-end`.
- Failed runs preserve the pending window; expired leases permit an identical retry.
- All incremental models read the same claimed lower and upper boundaries.
- No model reads `max(...)` of a target, its own or an upstream one, to bound its window.
- Source caps remain only for checkpoint-disabled compatibility behavior; checkpoint-enabled windows use the warehouse control row exclusively.
- Model-specific source lookbacks and state reconciliation remain in place.
- No model carries a processing stamp: `incremental_ts` is removed. Downstream models read changed rows by `updated_ts` (or `to_ts` for outages) and open rows directly.
- Full refresh and checkpoint-disabled run/build invocations use a deterministic bounded range beginning at `start_processing_date` and do not advance pipeline state.
- Incremental unit tests set their window with `overrides: vars: {start_processing_date: ...}` because dbt unit tests do not execute lifecycle hooks.

## Activation

Checkpoint mode remains explicit:

```text
dbt build --exclude "test_type:unit" --vars '{incremental_checkpoint_enabled: true}'
```

Production must use the complete DAG when checkpoint mode is enabled. Partial production selections can finalize a shared window for models that were not selected and are therefore unsupported.

CI remains checkpoint-disabled unless it receives an isolated checkpoint initialization and selection strategy.

## Production state

A one-off production run on `refactor/incremental_checkpoint` initialized and exercised an empty checkpoint window successfully. The production checkpoint is completed at `2025-10-15T07:55:00.100Z`, with no pending claim or lease.

The scheduled production job still runs full refresh until the feature is promoted and its command is updated.

## Known rollout blocker

A populated-window replay over already-loaded development targets is not idempotent. Nullable merge keys produce duplicate `int_meter_values` groups, and `fact_charge_attempts` receives duplicate merge matches. The checkpoint correctly remains pending, but production cutover must wait until replay is fixed and revalidated.

## Operational recovery

- Inspect state with `dbt run-operation show_incremental_checkpoint`.
- Initialize or reset state only with an explicit timestamp using `dbt run-operation initialize_incremental_checkpoint`.
- An active lease blocks overlap.
- An expired lease permits the next build to reclaim the same pending window.
- Never advance a checkpoint manually beyond data represented by a successful full refresh or incremental build.

## Remaining rollout work

1. Fix populated-window replay idempotency in `int_meter_values` and `fact_charge_attempts`.
2. Revalidate a populated window, forced failure, and identical-window retry.
3. Promote the checkpoint implementation through the repository deployment branches.
4. Update the production job to the checkpoint-enabled command.
5. Trigger and inspect the first scheduled-equivalent run.
6. Monitor several populated windows for successful advancement and replay behavior.
