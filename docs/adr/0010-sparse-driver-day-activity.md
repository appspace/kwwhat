# 0010. Sparse driver-day activity

- Status: Proposed
- Date: 2026-11-03
- Related: `models/marts/fact_driver_activity_daily.sql`, ADR 0003, ADR 0008

## Context

`int_driver_aggregates` and `dim_drivers` retain first/last observed activity but cannot
reconstruct distinct active drivers for arbitrary historical periods. A dense snapshot
would store every driver on every date, including dates without activity. We need a
compact historical building block for later rolling active-driver and growth accounting
metrics without fixing those metric definitions in a SQL mart.

## Decision

Add `fact_driver_activity_daily`, a factless table with one row per known driver per
calendar date on which at least one charge attempt started, across the entire network.
Both successful and unsuccessful attempts establish presence. Exclude null id_tags and
the reserved `UNKNOWN` / `__UNKNOWN__` markers. An id_tag identifies an observed credential,
not necessarily a unique person. Inactive driver-days are absent.

Cast the canonical `charge_attempt_start_ts` directly to DATE, preserving its existing
timestamp basis without introducing a timezone conversion. Generate `driver_key` from
id_tag exactly as in `dim_drivers` (ADR 0003), and `driver_activity_id` from id_tag + date_id.
Store only those keys, date_id, and the technical `_incremental_ts` watermark.

Use the existing model-local bounded incremental window (ADR 0008). Read changed attempts
by updated_ts, deduplicate their driver/date pairs, and merge by driver_activity_id.
A late event can add an older activity date when its updated_ts enters the current window.
Repeated activity for an existing pair replaces the same presence row rather than adding
counts. No additional checkpoint system or sentinel business rows are introduced.

Leave semantic metrics unchanged in this change. Future rolling distinct-driver metrics
must count distinct driver_key across the requested window. Daily driver counts cannot be
summed to obtain a weekly or monthly distinct-driver count.

## Alternatives considered

- Dense driver-day snapshots: store inactive dates unnecessarily for this use case.
- Bit-packed activity state: compact current history, but introduces bounded history,
  advancement, late-correction, and adapter-specific bit-operation complexity.
- First/last seen only: sufficient for current trailing-active counts but loses the
  activity history needed for past as-of dates and period comparisons.

## Consequences

Storage scales with observed driver-days, not all possible driver/date combinations.
Rolling historical queries still scan the relevant activity dates. Add warehouse-specific
physical optimizations only after measuring actual scan cost.

The processing watermark is distinct from activity dates. Inherited bounded windows mean
initial population and rebuilds may require multiple invocations to catch up. A window
without known-driver activity emits no rows and cannot advance its local watermark;
follow ADR 0008 operational investigation and explicit recovery rather than inserting
sentinel rows. This change does not extend the accepted sparse-outage exception.

This is presence accumulation, not change-data-capture reconciliation. Source deletions,
reassignment of an attempt to another driver/date, or changes behind the watermark require
an explicit backfill or rebuild that also removes stale presence rows. Rebuilding against
only retained source history cannot recover activity older than that history.

SQL uses portable casts, grouping, and the existing incremental-window macro. Validation
on Snowflake alone does not certify BigQuery execution.
