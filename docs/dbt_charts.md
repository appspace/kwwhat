# dbt Charts

The starter board at `charts/charging_overview.yml` shows daily authenticated
drivers and anonymous visits by location, visit outcomes, and a location summary.
`dbt_charts.yml` declares its connection.

## Connection and data scope

- This board uses Snowflake SQL and reads the confirmed deployed relation
  `analytics.dbt_prod.fact_visits` explicitly. Changing the connection's default
  schema does not redirect the board to development data.
- The connection uses the `kwwhat` profile declared in `dbt_project.yml` and that
  profile's default target (no `target:` is pinned in `dbt_charts.yml`). Studio
  manages its own connection; its credentials are not exported by this configuration.
- The Snowflake role needs SELECT access to the deployed mart and USAGE on its
  database, schema, and warehouse. Keep credentials in `profiles.yml` or its
  environment variables, never in board files or Git.
- The board is Snowflake-specific. It does not target the separate DuckDB demo.

## Preview locally

See the [dbt Charts quickstart](https://docs.getdbt.com/guides/dbt-charts).
Verified with `dbt-charts` 0.12.0, `dbt-snowflake` 1.11, Python 3.12. Install it
into the project `.venv` (this also adds `dbt-duckdb` and bumps `dbt-protos`;
`dbt-core` is unchanged):

```bash
uv pip install --python .venv/bin/python dbt-charts
source .venv/bin/activate
```

From the project root, with your local connection configured:

```bash
dct validate charts/charging_overview.yml
dct serve
```

Open the URL printed by `dct serve` and choose `charging_overview.yml`.
For static HTML output:

```bash
dct render charts/charging_overview.yml --format html
```

## Brand colors

`charts/meta.yml` extends `charts/_brand.yml` for every board under `charts/`.
The palette comes from `demo/chat-bi/rules.md`; keep the two in sync. The
leading underscore keeps `_brand.yml` from being served as a board.

`charging_overview.yml` pins colors to exact query values, so a renamed value
loses its pin and falls back to the palette:

- Each location keeps one hue: LOC-001 purple, LOC-002 turquoise, LOC-003
  bluish. The dark shade is authenticated and a light tint is anonymous, stacked
  on top. LOC-003's tint is `category[6].pale` because the brand has no light
  bluish. New locations take the next palette colors.
- Bar charts cannot set per-series opacity or borders, so the light tint stands
  in for a transparent anonymous segment.
- Outcomes: first-attempt success dark turquoise, troubled success turquoise,
  failed dark purple, in progress yellow.

## Date range and metric definitions

The board executes SQL, not live dbt Semantic Layer metric queries.

- A shared `date_range` variable (`input: daterange`) defaults to October 1
  through November 19, 2025. Presets such as `last_30_days` are also accepted
  as a `default`.
- All three queries use `{{ filter_date_range('visit_end_ts', date_range) }}`, a
  Charts template helper (not a dbt macro). It compares the timestamp by its
  calendar date with `between`, so both the start and end dates are inclusive.
- The existing `visit_end_ts` time basis is preserved. Visits whose end timestamp
  is null will be excluded by a date predicate, including visits still in progress.
- Daily counts are grouped by end date and `location_id`, then left joined onto
  a date spine from `analytics.dbt_prod.dim_dates` (filtered by the same
  `date_range`) crossed with the locations seen in the range. Days with no
  visits show as empty columns instead of disappearing from the axis, so gaps
  such as outages or a location not yet live stay visible.
- Authenticated counts are distinct non-null `id_tag` values per day and location.
  Repeat visits by the same authenticated driver count once in that group.
  Anonymous counts are distinct `visit_id` values where `id_tag` is null. These
  counts intentionally differ from the Semantic Layer's total visit count.
- The daily query reshapes the two counts into `authentication_type` and
  `visit_count` rows for plotting. Its color series combines location and
  authentication type.
- Outcome and location-summary definitions mirror
  `models/semantic/semantic_models.yml` and should be kept aligned with it.
- First-attempt success means `is_successful` is true and
  `charge_attempt_count = 1`. Troubled success means it is true and the
  attempt count is greater than one.
- Success rates are each outcome's share of all visits in the range (0 to 1,
  displayed as %), matching the Semantic Layer ratio metrics
  `first_attempt_success_rate`, `troubled_success_rate` and `failed_rate`.
- A null success status means in progress, not failed. A false status means failed.
- Average attempts per visit is the sum of attempt counts divided by the visit
  count, with a guard against division by zero.

Keep setup documentation outside `charts/`: every YAML and Markdown file under
that directory becomes a served page.

## Validation status

Verified locally on 2026-11-21 with `dbt-charts` 0.12.0: `dct validate` passes, and
all three queries execute against `analytics.dbt_prod.fact_visits` with the default
date range, and a PNG render shows the brand pins applied. No dbt models or metric definitions were changed.
