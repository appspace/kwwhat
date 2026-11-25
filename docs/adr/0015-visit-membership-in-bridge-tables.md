# 0015. Visit membership lives in bridge tables, not array columns

- Status: Proposed
- Date: 2026-11-25
- Related: #174, #159, `int_visits`, `fact_visits`, `bridge_visit_chargers`, `bridge_visit_charge_attempts`

## Context

`fact_visits` stored `charger_ids` and `charge_attempt_ids` as array columns. Counting or filtering
visits by member charger or charge attempt needed array functions, and BI tools and the semantic
layer cannot join on an array. The arrays are also what the incremental merge uses to extend a
visit across runs.

## Decision

- `int_visits` holds the visit grouping and incremental merge logic, including the member arrays.
  The arrays stay internal to this model and are sorted so the output is deterministic.
- `fact_visits` is a plain table over `int_visits`, one row per visit, without the arrays. It
  computes its dimension keys in place (see [0003](0003-facts-generate-dimension-keys-in-place.md))
  and passes `_incremental_ts` through, because `int_driver_aggregates` reads it as its change
  feed (see [0011](0011-visit-based-driver-first-last-seen.md)).
- `bridge_visit_chargers` (one row per visit and charger) and `bridge_visit_charge_attempts` (one
  row per visit and charge attempt) unnest the arrays for joins and tests.
- Visit measures stay at visit grain. A visit that used two chargers appears under both in the
  charger bridge, so charger membership is non-additive: energy and duration belong to the visit
  and are not attributed in full to each charger. Any charger attribution must be defined separately.
- The bridge semantic models are dimension-only. They do not support slicing visit measures by
  charger, because joining from the visit primary entity to a bridge foreign entity fans out, which
  MetricFlow blocks.

## Alternatives considered

- **Keep arrays in `fact_visits`.** No migration, but BI tools and the semantic layer cannot use them.
- **Make a visit-to-attempt mapping the canonical relationship.** The grouping logic would write one
  row per visit and attempt, visit aggregates would derive from it, and charger membership would
  derive through the attempts. That removes the array merge machinery. It is deferred to a follow-up
  because `visit_id` can change when a visit is extended backwards, and a row-based mapping has to
  reassign or delete rows when that happens.

## Consequences

- Breaking change: `fact_visits.charger_ids` and `fact_visits.charge_attempt_ids` are gone. Join the
  bridge tables on `visit_id` instead.
- `fact_visits` rebuilds fully on each run. This is cheap at the current size.
- `int_visits` must exist before its incremental unit tests run, because they read its own columns.
  On a fresh schema, run `dbt run --select int_visits` once first.
- The array merge logic remains in `int_visits` until the canonical mapping follow-up lands.
