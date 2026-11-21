# 0014. First-attempt success, troubled success and failed rates might not add up to 1

- Status: Proposed
- Date: 2026-11-21
- Related: [0013](0013-attempt-success-includes-authorization-and-failure-reason.md),
  `models/semantic/semantic_models.yml`

## Context

[0013](0013-attempt-success-includes-authorization-and-failure-reason.md) makes an attempt in progress
neutral: while its transaction is open, or while it has no transaction and the connector is still in
Preparing, the attempt, and a visit whose last attempt it is, is neither successful nor failed
(`is_successful` is null). The three visit reliability rates, `first_attempt_success_rate`,
`troubled_success_rate` and `failed_rate`, divide by `total_visits`. Before, every visit was either
successful or failed, so the three added up to 1. A neutral visit is in the denominator and in none of the
numerators.

## Decision

- Keep `total_visits` as the denominator of all three rates.
- Accept that `first_attempt_success_rate + troubled_success_rate + failed_rate` might not add up to 1. It
  can be less: the remainder is the share of visits still in progress, which no rate counts as a success or a
  failure.
- Count failures with `not is_successful`, so a neutral visit or attempt isn't counted as failed.
- Aggregate visits for reliability by when they stop (`visit_end_ts`), not when they start. A visit's outcome
  is known only once it ends, so cut by end, the only visits without an outcome are those still in progress.
  `visit_end_ts` is the `visits` semantic model's `agg_time_dimension`, and both timestamps' descriptions say
  which one to use. The same holds for charge attempts: `charge_attempts` aggregates by
  `charge_attempt_stop_ts`, not `charge_attempt_start_ts`.
- Say so in each rate's description in the semantic model and in the README's metrics table.

## Alternatives considered

- **Divide by visits with a known outcome** (a `completed_visits` metric, successful plus failed). The rates
  would always add up to 1, but that hides whatever falls out of the denominator. A subset of attempts that
  never reaches an outcome, such as transactions whose StopTransaction never arrives, would silently drop off
  the radar instead of showing as a gap. It also adds a metric whose only use is as a denominator.

## Consequences

- On data where every transaction has stopped, nothing changes: the rates add up to 1, as before.
- Where some transactions are open, typically at the end of the data, the rates add up to less than 1. The
  gap is the share of visits still in progress, and it shrinks as those attempts finish.
- Only open transactions show in the gap. An open transaction's attempt has a stop time (when the connector
  left Preparing), so its visit has a `visit_end_ts` and falls in a period. An attempt still in Preparing has
  no stop time yet, so its visit has no `visit_end_ts` and isn't in any period, in the denominator or the
  numerators, until the connector reports its next status.
- A reader can't take `1 - failed_rate` as the success rate. Use the success rates themselves, or
  `total_successful_visits`.
- The gap is a signal, not noise. A gap that stays after the end of the data has moved on points to
  attempts stuck without an outcome, for example a StopTransaction that never arrives, which keeps its visit
  in the gap indefinitely.
- A gap also surfaces bad metric design. A rate cut by when attempts or visits started, rather than when they
  finished, counts visits whose outcome isn't known yet in the period they began, and the rates of recent
  periods stop adding up to 1. Because the visit rates are cut by `visit_end_ts`, a gap in them comes only
  from visits still in progress.
