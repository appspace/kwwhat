# dbt Charts

The starter board at `charts/charging_overview.yml` shows daily authenticated
drivers and anonymous visits by location, visit outcomes, and a location summary.
`dbt_charts.yml` declares its connection.

## Connection and data scope

- This board uses Snowflake SQL and reads the confirmed deployed relation
  `analytics.dbt_prod.fact_visits` explicitly. Changing the connection's default
  schema does not redirect the board to development data.
- The connection uses the `kwwhat` profile declared in `dbt_project.yml`, with
  target `default`. Supply that profile and target in your local `profiles.yml`,
  or update `dbt_charts.yml` to match your local profile and target. Studio manages
  its own connection; its credentials are not exported by this configuration.
- The Snowflake role needs SELECT access to the deployed mart and USAGE on its
  database, schema, and warehouse. Keep credentials in `profiles.yml` or its
  environment variables, never in board files or Git.
- The board is Snowflake-specific. It does not target the separate DuckDB demo.

## Preview locally

Use Python 3.9+ and dbt 1.12+ as described in the
[dbt Charts quickstart](https://docs.getdbt.com/guides/dbt-charts).
The current Charts quickstart also requires the Python v1 adapter when using
v2 Stable. Install the Snowflake adapter and Charts in your Python environment:

```bash
pip install dbt-snowflake dbt-charts
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

## Date range and metric definitions

The board executes SQL, not live dbt Semantic Layer metric queries.

- A shared `date_range` variable is declared with a proposed default of October 1
  through November 19, 2025. The `type: date_range` control declaration, two-date
  default format, and end-date inclusivity still require validation with the
  installed Charts version. They have not been verified in Studio.
- All three queries use the user-supplied helper pattern:
  `{{ filter_date_range('visit_end_ts', date_range) }}`. Charts must render this
  expression before the SQL is sent to Snowflake; it is not a dbt macro.
- The existing `visit_end_ts` time basis is preserved. Visits whose end timestamp
  is null will be excluded by a date predicate, including visits still in progress.
- Daily counts are grouped by end date and `location_id`. Missing dates are not
  zero-filled.
- Authenticated counts are distinct non-null `id_tag` values per day and location.
  Repeat visits by the same authenticated driver count once in that group.
  Anonymous counts are distinct `visit_id` values where `id_tag` is null. These
  counts intentionally differ from the Semantic Layer's total visit count.
- The daily query reshapes the two counts into `authentication_type` and
  `visit_count` rows for plotting. Its interim color series combines location and
  authentication type. Shared location colors, lighter anonymous fills, solid
  authenticated fills, and the final stacking behavior still need renderer
  verification; no unverified opacity configuration is included.
- Outcome and location-summary definitions mirror
  `models/semantic/semantic_models.yml` and should be kept aligned with it.
- First-attempt success means `is_successful` is true and
  `charge_attempt_count = 1`. Success after retries means it is true and the
  attempt count is greater than one.
- A null success status means in progress, not failed. A false status means failed.
- Average attempts per visit is the sum of attempt counts divided by the visit
  count, with a guard against division by zero.

Keep setup documentation outside `charts/`: every YAML and Markdown file under
that directory becomes a served page.

## Validation status

Earlier literal-date SQL queries were executed against the deployed mart from
Studio. The new Charts date-range control and templated predicates have not been
rendered or executed. No dbt models or metric definitions were changed. Studio's
tools cannot run `dct`, install Python packages, or host its server. Use the local
validation and preview steps above to check the variable declaration, SQL helper
expansion, range boundaries, and browser behavior before relying on this version.
