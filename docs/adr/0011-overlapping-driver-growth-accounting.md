# 0011. Overlapping-window driver growth accounting

- Status: Proposed
- Date: 2026-11-03
- Related: ADR 0010, `models/semantic/semantic_models.yml`, `tests/assert_driver_activity_first_seen_consistent.sql`

## Context

Sparse driver-day activity supports historical distinct-driver counts without storing
inactive driver-days. We need trailing 7-day and 30-day active-driver metrics and growth
accounting that compares overlapping periods, as requested by the metric owner.

## Decision

Define all metric calculations in the dbt Semantic Layer, keeping the existing legacy
semantic YAML format. Reuse `dim_dates` as the configured time spine and
`fact_driver_activity_daily` as the activity source. Count distinct driver_key over each
window, never sum daily distinct counts. Activity means any identified charge attempt,
successful or unsuccessful, network-wide. Driver means an observed id_tag credential,
not a resolved human identity. Reserved unknown markers remain excluded.

For an as-of date D and window N (7 or 30 days):

- Current active set: activity on D-N+1 through D inclusive.
- Previous active set: activity on D-N through D-1 inclusive.
- Retained: intersection of those two sets, even if the driver did not charge on D.
- New: first-ever observed activity on D, from dim_drivers.first_seen_ts.
- Resurrected: in the current set, absent from the previous set, and first observed before D.
- Churned: in the previous set and absent from the current set. This is expiry from the
  activity window, not permanent customer loss.

New is a daily entrant count shared by both window lengths. It does not mean all drivers
acquired within the trailing window. First-ever means first observed in retained project
history; activity before source coverage is not knowable.

The union of current and previous sets is the trailing N+1-day set. Use semantic-layer
8-day and 31-day cumulative distinct-count helpers, and derive:

- retained = current + previous - union
- resurrected = current - retained - new
- churned = previous - retained

Previous is the corresponding cumulative metric offset by one day. This gives the checks
active = new + retained + resurrected, and current - previous = new + resurrected - churned.
No additional physical state table or precomputed SQL metric is introduced.

Use metric_time__day for growth accounting. Active cumulative metrics use period_agg: last
for coarser queries, but that does not make coarser growth-accounting queries valid. Monthly
acquisitions and monthly retention are different questions and are not defined here.

Query completed, fully ingested as-of dates only. Neither a time spine row nor a zero-filled
metric proves source completeness. Set an explicit date range in queries, cap it to a known
complete source cutoff, and allow enough prehistory for the N+1-day comparison. The first
comparison dates after the processing start have truncated prior history and must be treated
as warm-up. Filters on activity dates can truncate the lookback; filter metric_time instead.

## Alternatives considered

- Non-overlapping consecutive windows: useful period reporting, but the requested accounting
  compares adjacent daily rolling snapshots.
- A dense driver-day state table: unnecessary storage for counts that can be derived from
  distinct set cardinalities.
- Subtracting previous active counts alone: yields net change but cannot separate retention,
  resurrection, and expiry.

## Consequences

Repeated drivers are deduplicated across the entire window. Retention counts may be high
because consecutive windows overlap by N-1 days. New, resurrection, and churn are flows;
retained is a set-intersection stock, and must not be summed across dates.

The first-seen dimension and sparse activity must remain aligned. Add a data test comparing
first activity dates to the dimension through the activity processing watermark; stale or
incomplete histories should fail visibly rather than be hidden by clamping negative values.
Late arrivals can revise historical acquisitions and window membership. Existing source
retraction and watermark limitations from ADR 0010 still apply.

Scope accounting to network-wide daily counts or shared driver attributes. The sparse fact
has no location/port grain, so local new-driver or local retention metrics are not defined.
Current driver attributes are Type 1 and do not provide historical attribute segmentation.


Validate the configured derived expressions against synthetic driver sets for both window
lengths, including boundary returns, repeated activity, no-new-driver days, and inactive
windows. This arithmetic test complements first-seen alignment checks and MetricFlow
warehouse validation; it does not replace query-planner or runtime checks.

The OSI export currently cannot represent cumulative window semantics. Use the dbt Semantic
Layer to consume these metrics; OSI exports are not an equivalent rolling-metric contract.
