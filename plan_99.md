# Plan — Issue #99

Issue: https://github.com/appspace/kwwhat/issues/99
Branch: `issue_99/document-non-additive-measures`

## Goal

Document two non-additive mart measures so downstream BI and semantic-layer consumers do not accidentally aggregate them with `SUM` or naive averages.

No mart SQL changes are planned.

## Draft PR Summary

This issue establishes the aggregation contract for two mart measures that can
silently produce incorrect BI results when rolled up:

- `fact_uptime.uptime` is a 0-1 ratio and must be rolled up as a
  commissioned-minute weighted average.
- `fact_interval_data.avg_value` is a pre-aggregated average and must be
  re-aggregated using `_count` as its observation weight.

The proposed change is documentation and semantic-layer configuration only; no
mart SQL or ChatBI/golden-test changes are proposed. The current
`average_uptime` semantic metric remains an unweighted average over port-day
rows, not true fleet/network uptime. A true fleet/network metric would require
commissioned minutes to be available in the mart or semantic model.

## Decision Requested

Please confirm whether the documentation-only approach is sufficient for #99,
and whether exposing commissioned minutes for a true weighted uptime metric
should be tracked as a follow-up issue.

## Scope

In scope:

- Update column descriptions in `models/marts/marts.yml`.
- Verify `fact_uptime.uptime` already has an accepted range test from 0 to 1.
- Update semantic-layer descriptions for uptime in `models/semantic/semantic_models.yml`.
- Note that `fact_interval_data.avg_value` is not currently referenced by semantic models.

Out of scope:

- Changing mart SQL.
- Exposing commissioned minutes in `fact_uptime`.
- Fixing unrelated ChatBI/golden-test behavior.
- `snowflake/semantic_view.yml` — not present in this repo branch.

## Files To Read

1. `models/marts/fact_uptime.sql`
2. `models/marts/fact_charger_commissioned_daily.sql`
3. `models/marts/fact_interval_data.sql`
4. `models/marts/marts.yml`
5. `models/semantic/semantic_models.yml`

## Implementation Steps

1. Update `fact_uptime.uptime` description in `models/marts/marts.yml`.
   - State that it is a ratio from 0 to 1.
   - State that it is non-additive.
   - Document correct roll-up as weighted average by commissioned minutes:
     `SUM(uptime * minutes) / SUM(minutes)` via `fact_charger_commissioned_daily`.

2. Update `fact_interval_data.avg_value` description in `models/marts/marts.yml`.
   - State that it is a pre-aggregated average over the 15-minute interval.
   - State that it is non-additive.
   - Document correct roll-up as weighted average by `_count` for the same `measurand`, `unit`, and `phase`:
     `SUM(avg_value * _count) / SUM(_count)`.

3. Optionally strengthen `_count` description.
   - Mention that `_count` is the observation count used as the weight when re-aggregating `avg_value` within the same `measurand`, `unit`, and `phase`.

4. Verify `fact_uptime.uptime` accepted range test.
   - Expected existing test:
     `dbt_utils.accepted_range` with `min_value: 0` and `max_value: 1`.
   - No change needed if already present.

5. Update `models/semantic/semantic_models.yml`.
   - Confirm `uptime_average` uses `agg: average`, not `sum`.
   - Add description note that this is an unweighted average over port-day rows.
   - Document that network/fleet uptime requires commissioned-minute weighting.
   - Confirm no semantic model currently references `fact_interval_data.avg_value`.

## Validation

Run:

```bash
dbt parse
dbt test -s fact_uptime fact_interval_data
```

If local dbt/profile access is unavailable, document the blocker in the PR and mention that the change is YAML/docs-only.

Local status:

- YAML syntax check passed for `models/marts/marts.yml` and `models/semantic/semantic_models.yml`.
- `dbt` is not installed in this environment (`command not found`), so `dbt parse` and `dbt test` still need to run before/inside PR validation.

## PR Notes

Suggested title:

```text
docs: document non-additive measures in fact_uptime and fact_interval_data (#99)
```

Suggested summary:

- Document `fact_uptime.uptime` as a non-additive 0-1 ratio with commissioned-minute weighted roll-up.
- Document `fact_interval_data.avg_value` as a non-additive pre-aggregated average with `_count` weighted roll-up.
- Update uptime semantic descriptions in dbt semantic YAML.
- Verify `fact_uptime.uptime` already has a 0-1 accepted range test.

Semantic note:

- `uptime_average` currently uses `average`, not `sum`.
- This is an unweighted average across port-day rows.
- True network/fleet uptime requires weighting by commissioned minutes (`fact_charger_commissioned_daily.minutes`).
- No semantic model currently references `fact_interval_data.avg_value`.

## Open Questions / Follow-Ups

These are not blockers for #99, but should be visible to reviewers:

1. Should a future issue expose commissioned minutes in `fact_uptime` or a semantic model so `average_uptime` can become a true commissioned-minute weighted metric instead of the current unweighted average?
2. `models/semantic/README.md` still references `snowflake/semantic_view.yml`, but that file is not present in this repo branch. Should that README reference be removed or should the Snowflake semantic view file be restored in a separate PR?

## Acceptance Checklist

- [ ] `fact_uptime.uptime` description says ratio 0-1.
- [ ] `fact_uptime.uptime` description says non-additive.
- [ ] `fact_uptime.uptime` description documents weighted average by commissioned minutes.
- [ ] `fact_interval_data.avg_value` description says pre-aggregated average.
- [ ] `fact_interval_data.avg_value` description says non-additive.
- [ ] `fact_interval_data.avg_value` description documents weighted average by `_count` within the same measurand/unit/phase.
- [ ] `fact_uptime.uptime` has accepted range test from 0 to 1.
- [ ] Semantic uptime measure/metric does not use `SUM`.
- [ ] Semantic limitation for unweighted uptime average is documented.
- [ ] No mart SQL changes.
