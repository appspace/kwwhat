---
name: driver-period-cohorts
description: Split drivers with a charge attempt stopping in any selected timestamp period into new, retained, and resurrected cohorts using stop-time history and a fixed 30-day pre-period lookback. Use for intraday traffic changes, driver-mix investigations, and visit-success breakdowns.
---

# Selected-period driver cohorts

## When to use

Use this skill for selected-period driver activity, traffic mix, and visit-success
investigations, including "the last two hours" and matched historical periods.
These are query-derived analytical cohorts, not new published Semantic Layer metrics
or permanent driver attributes. MAD and 7-day accounting use the same stop-based activity
but retain their distinct daily rolling-window definitions. Do not reinterpret them as
this arbitrary-period calculation.

## Read project context first

- `repos/kwwhat/models/semantic/semantic_models.yml`: authoritative metric and outcome
  definitions, time attribution, entities, and measures.
- `repos/kwwhat/models/marts/marts.yml`: documented tables, columns, and stop-based history.
- [Sample query](references/period_driver_cohorts.sql): DuckDB SQL for documented
  `analytics.ANALYTICS.fact_charge_attempts` and `analytics.ANALYTICS.dim_drivers`.
- [Validation checklist](references/validation.md): boundary and coverage checks.

Follow the demo's DuckDB and mart-only access rules; no schema introspection is needed.
Outside the demo, discover exact relations and environment before adapting the SQL.
Confirm the stop-time migration and aligned history rebuild in ADR 0014 have been
applied. An old start-based first_seen_ts can silently misclassify drivers even when
it passes basic timestamp consistency checks. Do not mix old and migrated histories.

## 1. Establish the reporting period

Resolve concrete timestamps S and E in the canonical `charge_attempt_stop_ts` basis.
Validate S < E. Capture the clock once for relative periods and reuse both endpoints.
State the timezone/basis and clarify ambiguity; do not invent a timezone conversion.
Use validated timestamp parameters or ISO literals, never arbitrary user SQL expressions.

Use half-open windows:

- Current stops: **[S, E)**, inclusive S and exclusive E.
- Prior stops: **[S minus 30 days, S)**, inclusive lower bound and exclusive S.

The lookback is fixed at 30 days, independent of period length. It is not 30 calendar
dates or a calendar month. Anchor it to S, not E or each driver's first attempt.

Processing has a **35-minute SLA**. When the SLA is met, the expected processed cutoff
is the captured clock minus 35 minutes. Literal "last two hours" means
[clock minus 120 minutes, clock), with the latest 35 minutes provisional. "Latest fully
processed two hours" means [clock minus 155 minutes, clock minus 35 minutes).
Never silently shift the requested window. State the endpoints, SLA assumption, and any
known processing incident or late-arrival risk. Maximum event time or `_incremental_ts`
alone does not prove source completeness. The SLA does not establish visit finalization.

## 2. Establish the active-driver population

A driver is active when **at least one charge attempt stops in [S, E)**. Successful and
unsuccessful stopped attempts both count. Use `charge_attempt_stop_ts`, not attempt start,
transaction stop, visit end, `updated_ts`, ingestion time, or `_incremental_ts`.
A null stop does not establish activity. An attempt starting before S and stopping
inside the window counts; one starting inside and stopping at/after E does not.

Use observed `id_tag` credentials as identity, excluding null, UNKNOWN, and __UNKNOWN__.
Credentials are not resolved humans. Report unidentified attempt/visit volume separately;
do not count all anonymous activity as one driver.
Deduplicate to one active credential per entire selected period. Use timestamped
`fact_charge_attempts`; daily sparse activity cannot resolve intraday boundaries.
Do not sum hourly or daily distinct-driver counts.

## 3. Classify each active driver once

Use `dim_drivers.first_seen_ts` as the earliest observed **attempt stop**, across all
available network history. Do not derive first-ever activity from a period/30-day extract.
Do not use current `last_seen_ts` for historical classification; it may include stops
after S or E. First/last seen no longer mean attempt starts after ADR 0014's migration.

Find prior stops in [S minus 30 days, S) from timestamped attempts, restricted to current
active credentials for efficiency. Keep prior history network-wide even when current
traffic is location-filtered, unless a different local-cohort definition is explicit.
Do not restrict current or historical activity to successful attempts.

| Cohort | Definition among identified active drivers |
| --- | --- |
| `new` | First-ever observed attempt stop is in [S, E) |
| `retained` | First stop is before S, with at least one stop in [S minus 30 days, S) |
| `resurrected` | First stop is before S, with no stop in that preceding window |

A first-ever attempt starting before S and stopping inside the period is **new**.
Freeze membership for the entire period, including repeat attempts and visits.
Recompute cohorts whenever S changes, including each historical comparison period.
With complete, aligned history the three categories partition identified active drivers;
counts sum to the period's distinct active population. Churned and stale are inactive
and do not belong in this stack. No lifetime-population metric helper is required.

## 4. Check history before interpretation

Require one valid dimension row per active credential, a non-null first-stop timestamp,
and first stop no later than observed current or prior stops. The sample flags
`history_inconsistent` for violations. This is a diagnostic, not a fourth business cohort.
If nonzero, disclose it and do not claim an exhaustive split or use it for a mix explanation.
Never silently drop dimension misses or classify them as new/resurrected.

Missing prior stops establish resurrection only with complete 30-day coverage. First-ever
means first observed in available history; truncated history can make an old driver look
new. The bundled 14-day synthetic seed cannot establish a complete 30-day lookback or
lifetime history. Sample dates are illustrative. Never shift a requested live period to
seed dates. Reconcile dimension and attempt processing coverage before interpreting gaps.

## 5. Apply cohorts to visit-success investigations

Keep the one-row-per-driver `driver_cohorts` CTE; join once per visit by `driver_key`.
Do not join raw prior attempts to visits, which fans out counts. Keep unknown credentials
separate and validate visit counts before/after joining.

State visit population and time basis. Governed visits use `visit_end_ts`; this active
population uses attempt stops. The timestamps are not interchangeable. Preserve visits
without a cohort match using a left join, and distinguish unidentified visits from known
drivers outside the selected stop-active population. A subset of visits containing stops
in the period is not automatically all visits ending in that period.

Preserve mart `is_successful` and semantic definitions of visits, single-attempt success,
troubled success, failed visits, and attempts per visit. Do not recreate energy/status
thresholds. Label cohort breakdowns, derived success ratios, and estimates as ad hoc query
results, not newly published metrics.

Do not count ongoing visits as failed. `fact_visits` has no explicit finalized flag;
a non-null visit end or attempt stop does not guarantee a buffered visit cannot extend.
Use a reliable finalization/completion criterion or label recent outcomes provisional.
The 35-minute processing SLA addresses lag, not visit finalization.

Compare distinct drivers, visit counts/shares, success rates, and attempts per visit by
cohort. Explain overall success with **visit weights**, not driver weights. Match baseline
weekday/time and location or Charger mix, recomputing cohorts relative to each baseline S.
An ad hoc mix-adjusted expectation is sum(current cohort visit share multiplied by matched
historical cohort success rate). This is association, not proof of driver inexperience
causing failures. Report sample sizes, uncertainty, and unidentified/out-of-population/
inconsistent-history coverage. Never fill missing baseline rates with zero.

## 6. Present the answer

Start with the demo's metrics-at-a-glance table. State S, E, timestamp basis, environment,
stop-based activity, processing cutoff/SLA assumptions, and history caveats. Separate
governed visit metrics from query-derived cohort results. Show a three-way stack only
after population, migration, and quality checks pass.
No visits means an undefined success rate, not zero. No identified stops means zero
active drivers and undefined cohort shares. Do not infer a real dip from a hypothetical
prompt or average subgroup percentages without visit denominators.
