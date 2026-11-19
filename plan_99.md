# Plan — Issue #99

Issue: https://github.com/appspace/kwwhat/issues/99
Branch: `issue_99/document-non-additive-measures`

## Goal

Document two non-additive mart measures so downstream BI and semantic-layer
consumers do not accidentally aggregate them with `SUM` or naive averages.
Rename the exposed weight fields so their business meaning is clear to both
human consumers and agents, and expose the uptime weight where downstream
consumers can use it.

SQL changes are limited to column renames, exposing `fact_charger_commissioned_daicommissioned_minutes` in
`fact_uptime`, and the references required by those changes. The mart grain and
underlying uptime/interval calculations do not change.

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
- `fact_uptime` exposes `commissioned_minutes` so weighted uptime is available
  to the semantic layer and Nao correctness evals.

The `average_uptime` semantic metric is updated from an unweighted average over
port-day rows to a ratio of summed uptime minutes and summed commissioned
minutes. The Nao uptime eval expectations are updated to use the same weighted
aggregation contract.

## Review Decisions Incorporated

- Rename the actual mart field to `commissioned_minutes`, rather than using
  `commissioned_minutes` only as a documentation alias.
- Rename the exposed `fact_interval_data` field from the technical `_count` to
  the approved business-facing name `reading_count` before documenting it as a
  downstream aggregation weight.
- Expose `commissioned_minutes` in `fact_uptime` and fold the true weighted
  uptime metric into this PR rather than tracking it as a follow-up.
- Nao chat is the only known external consumer. Daria will update it after this
  change; this PR owns checking and updating the repository's uptime eval
  correctness expectations.
- Track the stale Snowflake README references separately in #149.
- Treat these changes as approved extensions of the original
  documentation-only scope for #99.

## Scope

In scope:

- Rename `fact_charger_commissioned_daily.minutes` to
  `commissioned_minutes` in the model output.
- Update `fact_uptime` and every other repository reference to the renamed
  commissioned-minutes field.
- Expose `commissioned_minutes` in the `fact_uptime` output and schema
  documentation.
- Rename the exposed `fact_interval_data._count` field to `reading_count` and
  update its incremental merge/re-aggregation references.
- Update affected tests, schema declarations, descriptions, and formulas to
  use the new names consistently.
- Document the non-additive aggregation contracts in `models/marts/marts.yml`.
- Verify `fact_uptime.uptime` has an accepted range test from 0 to 1 inclusive.
- Update semantic-layer descriptions for uptime in
  `models/semantic/semantic_models.yml`.
- Replace the unweighted `average_uptime` semantic aggregation with a
  commissioned-minute weighted ratio.
- Update only the uptime metric wording in `models/semantic/README.md`; the
  unrelated Snowflake cleanup remains in #149.
- Update the Nao uptime eval expectations and verify that the uptime eval still
  runs.
- Note that `fact_interval_data.avg_value` is not currently referenced by a
  semantic model.

Out of scope:

- Changing the uptime or interval-average calculations.
- Renaming technical `_count` fields in intermediate models unless a direct
  dependency requires it. `int_meter_values._count` remains internal.
- Changing unrelated Nao/ChatBI behavior or evals.
- Updating the Nao chat application after the schema change; Daria owns that
  external-consumer follow-up.
- Cleaning up stale Snowflake semantic view references; tracked in #149.

## Files To Review And Update

1. `models/marts/fact_charger_commissioned_daily.sql`
2. `models/marts/fact_uptime.sql`
3. `models/marts/fact_interval_data.sql`
4. `models/marts/marts.yml`
5. `models/marts/unit_tests.yml` if fixtures or expectations reference either
   renamed field
6. `models/semantic/semantic_models.yml`
7. `models/semantic/README.md` for the uptime metric definition only
8. `demo/chat-bi/tests/network_reliability_uptime.yml`
9. `demo/chat-bi/tests/lately_snapshot.yml`
10. Any additional references returned by a repository-wide search for
   `minutes`, `_count`, `commissioned_minutes`, and `reading_count`

## Implementation Steps

1. Rename the commissioned-minutes field.
   - Change the public output of `fact_charger_commissioned_daily` from
     `minutes` to `commissioned_minutes`.
   - Update the model description and schema declaration.
   - Update `fact_uptime` to consume `commissioned_minutes` and use that name
     consistently in its internal calculation.
   - Include `commissioned_minutes` in the public `fact_uptime` output and
     document it as the additive weight for uptime roll-ups.
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
     `SUM(uptime * commissioned_minutes) / SUM(commissioned_minutes)` using
     `fact_uptime.commissioned_minutes`.
   - State that each port-day inherits the charger-day `commissioned_minutes`.
     The network roll-up therefore weights commissioned port-minutes, and a
     multi-port charger contributes once per port.

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
   - Expose additive numerator and denominator measures based on
     `uptime * commissioned_minutes` and `commissioned_minutes`.
   - Define `average_uptime` as their ratio so roll-ups are weighted by
     commissioned minutes rather than averaged across port-day rows.
   - Remove or replace the existing unweighted `uptime_average` measure so it
     cannot continue to back a misleading metric.
   - Document the weighted aggregation contract.
   - Update the uptime metric definition in `models/semantic/README.md` without
     including the separate Snowflake cleanup tracked in #149.
   - Confirm no semantic model currently references
     `fact_interval_data.avg_value`.

7. Update and run the Nao uptime correctness evals.
   - Update `network_reliability_uptime.yml` to expect
     `SUM(uptime * commissioned_minutes) / SUM(commissioned_minutes)` instead
     of `AVG(uptime)`.
   - Update the uptime expectation in `lately_snapshot.yml` to use the same
     weighted formula.
   - Confirm both uptime evals are still discovered and run by the current Nao
     test command.

8. Audit rename impact.
   - Search the full repository for both old field names after the edits.
   - Distinguish unrelated generic uses of `minutes` and internal uses of
     `_count` from references to the renamed mart columns.
   - Record Nao chat as the only known external consumer and Daria's ownership
     of its post-change update in the PR notes.

9. Plan the incremental schema migration.
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

Run the existing Nao test harness and confirm that both uptime scenarios are
discovered and execute:

- `demo/chat-bi/tests/network_reliability_uptime.yml`
- `demo/chat-bi/tests/lately_snapshot.yml`

The expected SQL for both scenarios must use the commissioned-minute weighted
formula rather than `AVG(uptime)`.

Local status:

- YAML syntax was checked for `models/marts/marts.yml` and
  `models/semantic/semantic_models.yml` before the rename scope was added.
- `dbt` is not installed in this environment (`command not found`), so the dbt
  parse, run, and test commands still need to run before or during PR
  validation.
- The two uptime eval definitions are present in the repository and currently
  expect `AVG(uptime)`; their weighted expectations and execution still need
  validation.

## PR Notes

Suggested title:

```text
fix: correct non-additive aggregation contracts and weight fields (#99)
```

Suggested summary:

- Rename `fact_charger_commissioned_daily.minutes` to
  `commissioned_minutes`, expose it in `fact_uptime`, and update downstream
  references.
- Rename exposed `fact_interval_data._count` to `reading_count` and update its
  incremental re-aggregation references.
- Document `fact_uptime.uptime` as a non-additive 0-1 ratio with a
  commissioned-minute weighted roll-up.
- Document `fact_interval_data.avg_value` as a non-additive pre-aggregated
  average with a reading-count weighted roll-up.
- Replace the unweighted `average_uptime` semantic metric with a
  commissioned-minute weighted ratio.
- Update and run the Nao uptime correctness evals.
- Verify the 0-1 accepted range test.

Semantic note:

- The current `uptime_average` measure is an unweighted average across port-day
  rows and must not continue to back `average_uptime`.
- The corrected `average_uptime` is a ratio of summed uptime minutes to summed
  `commissioned_minutes`.
- No semantic model currently references `fact_interval_data.avg_value`.

## Resolved Review Questions And Ownership

- **External consumers:** Nao chat is the only known external consumer. Daria
  will update it after this change. This PR verifies the repository's uptime
  eval coverage and expected weighted SQL.
- **Weighted uptime:** `commissioned_minutes` and the corrected weighted
  `average_uptime` are included in this PR, not deferred to a follow-up.
- **Snowflake README drift:** tracked separately in #149 because Cleanup #113
  intentionally removed the Snowflake Cortex assets.

No review questions remain open for the planned #99 implementation.

## Separate Issue

#149 tracks removal of stale `snowflake/semantic_view.yml` and
`snowflake/README.md` references from `models/semantic/README.md`. That docs
cleanup is intentionally outside #99.

## Acceptance Checklist

- [ ] `fact_charger_commissioned_daily.minutes` is renamed to
  `commissioned_minutes`.
- [ ] All repository references, tests, and descriptions for the renamed
  commissioned-minutes field are updated.
- [ ] `commissioned_minutes` is exposed and documented in `fact_uptime`.
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
- [ ] `average_uptime` is implemented as a commissioned-minute weighted ratio,
  not an unweighted average of port-day ratios.
- [ ] The old unweighted `uptime_average` measure is removed or no longer backs
  the primary uptime metric.
- [ ] The uptime metric definition in `models/semantic/README.md` reflects the
  weighted contract; Snowflake cleanup is left to #149.
- [ ] Both Nao uptime eval expectations use the weighted formula.
- [ ] Both Nao uptime evals are still discovered and execute in the test
  harness.
- [ ] No mart grain or underlying uptime/interval calculation changes are
  introduced.
