# Period-cohort validation checklist

S is inclusive, E exclusive, and L is S minus 30 days. All activity below means
`charge_attempt_stop_ts`; first_seen_ts must be the migrated earliest observed stop.
Inspect `driver_cohorts` at driver grain before extending the query to visits.

## Boundary cases

| Case | Fixture history | Expected result |
| --- | --- | --- |
| First stop at S | First-ever stop exactly S | New; included |
| First stop inside | First-ever stop between S and E | New |
| First attempt spans S | Start before S, first-ever stop inside | New |
| Start only inside | Start inside, stop at/after E or null | Outside unless another stop qualifies |
| Open only | No non-null stop | Outside |
| Repeated new | First stop in period, additional attempts/visits | One new driver throughout |
| Lookback boundary | Old driver, stop exactly L, current stop inside | Retained |
| Just before lookback | Old driver, last prior stop just before L | Resurrected when current stop qualifies |
| Same-day prior stop | First stop earlier on the same day before S | Retained when current stop qualifies |
| Return at S | First stop before L, no stop in [L, S), stop at S | Resurrected |
| Repeated return | Multiple current stops after resurrection | One resurrected driver |
| At E only | Only current stop exactly E | Outside |
| Never returns | Historical stops, none in [S, E) | Outside |
| Unknown credentials | Null, UNKNOWN, __UNKNOWN__ | Excluded |
| Missing dimension | Active credential has no row | history_inconsistent |
| Duplicate dimension | More than one row per active credential | history_inconsistent without fanout |
| Invalid dimension | Missing first_seen/key or false/null known flag | history_inconsistent |
| Future first seen | first_seen_ts later than observed current stop | history_inconsistent |
| Contradictory prior | first_seen_ts later than earliest observed prior stop | history_inconsistent |
| Later lifetime stop | last_seen_ts after E | No effect |
| Empty period | No identified stops in [S, E) | Zero drivers; undefined shares |

## Before reporting

- Confirm S < E, shared canonical timestamp basis, and one captured relative-period clock.
- Confirm ADR 0014's stop-based first/last seen migration and coordinated rebuild were
  applied. Old start-based values can pass basic checks and still misclassify drivers.
- Apply the 35-minute processing SLA conditionally on it being met. Literal last two hours
  remains [clock minus 120 minutes, clock); latest processed two hours is
  [clock minus 155 minutes, clock minus 35 minutes). Do not silently shift requested bounds.
- Check full 30-day prehistory and aligned processing coverage. The 14-day seed is
  insufficient, and an empty extract alone does not prove resurrection.
- Verify one row per active id_tag and no history_inconsistent rows; never hide misses.
- Independently count identified active credentials by stop time. With valid history,
  active = new + retained + resurrected. Use that population for cohort shares.
- An empty result means zero activity, not a SQL failure or resurrection count.
- Keep the original S when slicing the period into hours. Do not sum hourly distincts.
- Keep history network-wide when current traffic is filtered to a location.
- Recompute cohorts for each historical comparison's own S.

## Visit extension

Join one cohort per driver to visits by driver_key, checking counts before/after.
Preserve unmatched known-driver visits separately from unidentified visits. A visit-end
population and attempt-stop population need not match. Preserve the success flag and
never count ongoing visits as failed. Neither a non-null stop/end nor the processing SLA
proves a buffered visit is finalized.

Snowflake execution with development refs is a logic smoke test, not DuckDB or end-to-end
Chat BI validation. Run the sample in the demo runtime before claiming that it is verified.
