# 0011. Visit-based driver first and last seen

- Status: Proposed
- Date: 2026-11-04
- Related: ADRs 0008, 0010; int_driver_aggregates, dim_drivers

## Context

ADR 0010 based first and last seen on attempt stops. Driver questions are asked at visit level, so a driver's history should be comparable to the visits being counted.

With attempt stops, a driver whose first visit has attempts on either side of a period start S is counted as returning, even though it is their first visit. The visit ends inside the period, but `first_seen_ts` is before S. No period ever counts them as new.

## Decision

`first_seen_ts` and `last_seen_ts` are the earliest and latest `fact_visits.visit_end_ts` per credential. Visits with no `id_tag` accumulate under `__UNKNOWN__`.

`first_authorization_status` and `latest_authorization_status` are removed from `int_driver_aggregates`, `dim_drivers` and the `drivers` semantic model. Visits do not carry a status, so keeping them needs attempt history and extra columns only to order them, and nothing depends on them today. They can return with their own definition if a question needs them.

A visit's end can move later when it is extended, and a plain min/max merge would keep the stale earlier value. `int_driver_aggregates` therefore stores `first_visit_id` and `last_visit_id`. `visit_id` does not change when a visit is extended, so when a rewritten visit matches the stored id, it takes the visit's new end. Otherwise the earliest and latest values win. These two columns stay out of `dim_drivers`.

Each run reads only the current window and merges with stored state. Changed drivers are found with `fact_visits._incremental_ts`, and the model keeps a model-local watermark under ADR 0008.

## Alternatives considered

- Keep attempt stops and accept the edge case: leaves drivers who are never counted as new, which matters more for short periods.
- Compute the earliest visit end in each query: duplicates history logic and repeats a scan of all visits.
- Keep a plain min/max merge on visit ends: `first_seen_ts` would stay too early after a visit is extended.
- Recompute each changed driver from full history: exact with no extra columns, but every run scans history, and all anonymous visits whenever one is written.
- Add visit-based columns beside the attempt-based ones: two definitions of first seen invite mismatches.

## Consequences

- First and last seen can move for existing drivers, so `int_driver_aggregates` needs a rebuild, then `dim_drivers`. A rebuild follows the bounded window process in ADR 0010.
- Credentials whose attempts never join to a visit, such as an unmapped connector, are absent from `dim_drivers`.
- A visit whose `visit_id` changes no longer matches the stored id, so the merge falls back to earliest and latest until a rebuild. Issue #193 tracks how `fact_visits` handles late attempts, which is the known way this can happen.
- Overlapping visits by one driver at two locations can leave `first_seen_ts` slightly off if the first is extended past the other. This is accepted.
- Consumers of the two authorization status columns lose them. They are also dropped from existing tables on rebuild.
- A visit that gains an inferred `id_tag` can leave `__UNKNOWN__` stale until another anonymous visit is written.
- A window with no written visits does not advance the watermark, which is the existing ADR 0008 behavior.
- Attempt-stop activity and first seen no longer share a basis. Open PR #188 (driver activity and MAD lifecycle) assumes they do, because a driver can have an attempt stop on a day before their first visit end. That PR needs to move its activity to visit ends or otherwise reconcile the two before merging.
