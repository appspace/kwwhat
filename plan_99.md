# Plan — Issue #99

Issue: https://github.com/appspace/kwwhat/issues/99
Branch: `issue_99/document-non-additive-measures`

## Goal

Document two non-additive mart measures so downstream BI and semantic-layer
consumers do not accidentally aggregate them with `SUM` or naive averages.
Rename the exposed weight fields so their business meaning is clear to both
human consumers and agents.

SQL changes are limited to column renames and the references required by those
renames. No aggregation or mart business logic changes are planned.

## Draft PR Summary

This issue establishes the aggregation contract for two mart measures that can
silently produce incorrect BI results when rolled up:

- `fact_uptime.uptime` is a 0-1 ratio and must be rolled up as a weighted
  average using `commissioned_minutes`.
- `fact_interval_data.avg_value` is a pre-aggregated average and must be
  re-aggregated using `reading_count` as the number of raw meter readings that
  contributed to each interval average.

Following review, this change also renames the exposed fields that provide
those weights:

- `fact_charger_commissioned_daily.minutes` → `commissioned_minutes`.
- `fact_interval_data._count` → `reading_count`.

The current `average_uptime` semantic metric remains an unweighted average over
port-day rows, not true fleet/network uptime. A true fleet/network metric would
require commissioned minutes to be available in the uptime semantic model.

## Review Decisions Incorporated

- Rename the actual mart field to `commissioned_minutes`, rather than using
  `commissioned_minutes` only as a documentation alias.
- Rename the exposed `fact_interval_data` field from the technical `_count` to
  the approved business-facing name `reading_count` before documenting it as a
  downstream aggregation weight.
- Treat both renames as approved extensions of the original documentation-only
  scope for #99.

## Scope

In scope:

- Rename `fact_charger_commissioned_daily.minutes` to
  `commissioned_minutes` in the model output.
- Update `fact_uptime` and every other repository reference to the renamed
  commissioned-minutes field.
- Rename the exposed `fact_interval_data._count` field to `reading_count` and
  update its incremental merge/re-aggregation references.
- Update affected tests, schema declarations, descriptions, and formulas to
  use the new names consistently.
- Document the non-additive aggregation contracts in `models/marts/marts.yml`.
- Verify `fact_uptime.uptime` has an accepted range test from 0 to 1 inclusive.
- Update semantic-layer descriptions for uptime in
  `models/semantic/semantic_models.yml`.
- Note that `fact_interval_data.avg_value` is not currently referenced by a
  semantic model.

Out of scope:

- Changing the uptime or interval-average calculations.
- Exposing `commissioned_minutes` directly in `fact_uptime` or its semantic
  model.
- Renaming technical `_count` fields in intermediate models unless a direct
  dependency requires it. `int_meter_values._count` remains internal.
- Fixing unrelated ChatBI/golden-test behavior.
- `snowflake/semantic_view.yml` — not present in this repo branch.

## Files To Review And Update

1. `models/marts/fact_charger_commissioned_daily.sql`
2. `models/marts/fact_uptime.sql`
3. `models/marts/fact_interval_data.sql`
4. `models/marts/marts.yml`
5. `models/marts/unit_tests.yml` if fixtures or expectations reference either
   renamed field
6. `models/semantic/semantic_models.yml`
7. Any additional references returned by a repository-wide search for
   `minutes`, `_count`, `commissioned_minutes`, and `reading_count`

## Implementation Steps

1. Rename the commissioned-minutes field.
   - Change the public output of `fact_charger_commissioned_daily` from
     `minutes` to `commissioned_minutes`.
   - Update the model description and schema declaration.
   - Update `fact_uptime` to consume `commissioned_minutes` and use that name
     consistently in its internal calculation.
   - Update any tests or downstream references that use the old field name.

2. Rename the exposed interval reading count.
   - Change the public output of `fact_interval_data` from `_count` to
     `reading_count`.
   - Use `reading_count` consistently in that mart's weighted incremental
     re-aggregation logic and self-reference to `{{ this }}`.
   - Keep technical `_count` fields in intermediate models unchanged unless a
     direct dependency requires otherwise.
   - Update any tests or downstream references that use the old mart field.

3. Update `fact_uptime.uptime` documentation.
   - State that it is a ratio from 0 to 1.
   - State that it is non-additive.
   - Document the correct roll-up as a weighted average:
     `SUM(uptime * commissioned_minutes) / SUM(commissioned_minutes)` via
     `fact_charger_commissioned_daily`.

4. Update `fact_interval_data.avg_value` documentation.
   - State that it is a pre-aggregated average over the 15-minute interval.
   - State that it is non-additive.
   - Document the correct roll-up for the same `measurand`, `unit`, and `phase`:
     `SUM(avg_value * reading_count) / SUM(reading_count)`.
   - Describe `reading_count` as the number of raw meter readings contributing
     to the interval's `avg_value` and as the required downstream weight.

5. Verify the `fact_uptime.uptime` accepted range test.
   - Expected existing test: `dbt_utils.accepted_range` with `min_value: 0` and
     `max_value: 1`.
   - No test change is needed if the inclusive 0-1 guard is already present.

6. Update `models/semantic/semantic_models.yml`.
   - Confirm `uptime_average` uses `agg: average`, not `sum`.
   - Document that this is an unweighted average over port-day rows.
   - Document that true network/fleet uptime requires weighting by
     `commissioned_minutes`.
   - Confirm no semantic model currently references
     `fact_interval_data.avg_value`.

7. Audit rename impact.
   - Search the full repository for both old field names after the edits.
   - Distinguish unrelated generic uses of `minutes` and internal uses of
     `_count` from references to the renamed mart columns.
   - Confirm whether external consumers depend on either old column name and
     document any required coordination in the PR.

8. Plan the incremental schema migration.
   - `fact_interval_data` reads its existing `{{ this }}` relation during
     incremental runs and has no explicit `on_schema_change` configuration.
   - Use an approved full refresh or equivalent migration when replacing
     `_count` with `reading_count`; validate the deployment path before merge.

## Validation

Run:

```bash
dbt parse
dbt test -s fact_charger_commissioned_daily fact_uptime fact_interval_data
```

For the incremental schema rename, validate the approved migration path in a
non-production environment. If a full refresh is selected, run the equivalent
of:

```bash
dbt run --full-refresh -s fact_interval_data
```

Then run an incremental invocation to confirm that `{{ this }}` resolves
`reading_count` correctly.

Local status:

- YAML syntax was checked for `models/marts/marts.yml` and
  `models/semantic/semantic_models.yml` before the rename scope was added.
- `dbt` is not installed in this environment (`command not found`), so the dbt
  parse, run, and test commands still need to run before or during PR
  validation.

## PR Notes

Suggested title:

```text
fix: document non-additive measures and clarify weight fields (#99)
```

Suggested summary:

- Rename `fact_charger_commissioned_daily.minutes` to
  `commissioned_minutes` and update downstream references.
- Rename exposed `fact_interval_data._count` to `reading_count` and update its
  incremental re-aggregation references.
- Document `fact_uptime.uptime` as a non-additive 0-1 ratio with a
  commissioned-minute weighted roll-up.
- Document `fact_interval_data.avg_value` as a non-additive pre-aggregated
  average with a reading-count weighted roll-up.
- Update uptime semantic descriptions and verify the 0-1 accepted range test.

Semantic note:

- `uptime_average` currently uses `average`, not `sum`.
- This is an unweighted average across port-day rows.
- True network/fleet uptime requires weighting by `commissioned_minutes` from
  `fact_charger_commissioned_daily`.
- No semantic model currently references `fact_interval_data.avg_value`.

## Open Questions / Follow-Ups

These should remain visible to reviewers:

1. Do any external consumers depend on
   `fact_charger_commissioned_daily.minutes` or
   `fact_interval_data._count`, and if so, what compatibility or rollout plan
   is required for the schema renames?
2. Should a future issue expose `commissioned_minutes` in `fact_uptime` or an
   uptime semantic model so `average_uptime` can become a true
   commissioned-minute weighted metric instead of the current unweighted
   average?

## Separate Issue Candidate

During the review, `models/semantic/README.md` was found to reference
`snowflake/semantic_view.yml`, but that file is not present in this repo branch.

This is outside the scope of #99. Before opening a separate issue, check whether
one already exists. If not, ask whether an issue should be created to determine
whether the README reference should be removed or the Snowflake semantic view
should be restored.

## Acceptance Checklist

- [ ] `fact_charger_commissioned_daily.minutes` is renamed to
  `commissioned_minutes`.
- [ ] All repository references, tests, and descriptions for the renamed
  commissioned-minutes field are updated.
- [ ] The exposed `fact_interval_data._count` field is renamed to
  `reading_count`.
- [ ] All mart references, tests, formulas, and descriptions for the renamed
  reading-count field are updated.
- [ ] The incremental migration path for `fact_interval_data` is validated.
- [ ] `fact_uptime.uptime` is documented as a non-additive ratio from 0 to 1.
- [ ] The uptime roll-up formula uses `commissioned_minutes`.
- [ ] `fact_interval_data.avg_value` is documented as a non-additive,
  pre-aggregated average.
- [ ] The interval-average roll-up formula uses `reading_count` within the same
  `measurand`, `unit`, and `phase`.
- [ ] `fact_uptime.uptime` has an accepted range test from 0 to 1 inclusive.
- [ ] The semantic uptime measure/metric does not use `SUM`.
- [ ] The semantic limitation of the unweighted uptime average is documented.
- [ ] No aggregation or mart business logic changes are introduced.
