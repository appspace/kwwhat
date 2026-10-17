# 0008. Duration-weighted uptime

- Status: Proposed
- Date: 2026-10-17
- Related: `fact_uptime_daily`, `int_charger_commissioned_daily`, metrics `uptime_ratio`, `average_uptime` (removed), `total_downtime_minutes`

## Context

The only uptime metric, `average_uptime`, averages a ratio that `fact_uptime_daily` stores per
port-day. Every port-day counts the same, so a port commissioned for 10 minutes on its first day
weighs as much as a full 1440-minute day. Rolling up to a location or a month therefore gives a
different answer from "share of commissioned time that was up". The ratio was also computed in
mart SQL, outside the semantic layer.

`fact_uptime_daily` now carries the minutes behind the ratio: `commissioned_minutes`,
`downtime_minutes` (split into `offline_downtime_minutes` and `faulted_downtime_minutes`) and
`uptime_minutes`.

## Decision

- Replace `average_uptime` with `uptime_ratio`, a ratio metric:
  `total_uptime_minutes / total_commissioned_minutes`, both simple metrics summing the minute
  columns of `fact_uptime_daily`. `uptime_ratio` is the primary reliability metric.
- Remove `average_uptime` and its `uptime_average` measure, so there is one uptime number.
- `total_downtime_minutes` reads the port-day measure on `fact_uptime_daily`, matching the grain
  of `uptime_ratio`. Drill-down by `downtime_type`, `reason` and error code moves to
  `total_downtime_minutes_detailed`, on `fact_downtime_daily`.

## Alternatives considered

- **Keep only the average of daily ratios.** Simple, but wrong whenever port-days have different
  commissioned minutes, and the error grows with the grain of the query.
- **Fix the average in mart SQL** (pre-aggregate weighted uptime per location or month). Duplicates
  metric logic outside the semantic layer and only works at the grains we pre-build.
- **Redefine `average_uptime` in place.** Changes the value of an existing metric silently for
  every consumer, and the name would no longer describe how it is calculated.
- **Keep both metrics during a deprecation period.** Two metrics that both claim to be uptime
  confuse BI users and LLM agents choosing a metric; one governed number is clearer.

## Consequences

- Breaking: queries, dashboards and agents that use `average_uptime` must switch to
  `uptime_ratio`. Values shift slightly where port-days are partial (commissioning and
  decommissioning days).
- `uptime_ratio` is correct at any grain (port, charger, location, day, month).
- Queries that slice `total_downtime_minutes` by `downtime_type`, `reason` or error code must
  switch to `total_downtime_minutes_detailed`.
- The minute columns in `fact_uptime_daily` must stay consistent: `uptime_minutes =
  commissioned_minutes - downtime_minutes` and `downtime_minutes = offline_downtime_minutes +
  faulted_downtime_minutes` (the latter is tested).
