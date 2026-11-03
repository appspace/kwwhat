# 0012. Daily MAD lifecycle partition over overlapping 30-day windows

- Status: Proposed
- Date: 2026-11-03
- Related: ADR 0010, ADR 0011, `models/semantic/semantic_models.yml`, `tests/assert_mad_lifecycle_partition.sql`

## Context

The metric owner requested monthly active drivers (MAD) and five daily lifecycle
categories that can form a mutually exclusive and exhaustive stack. Existing 30-day
accounting already supplies new, retained, resurrected, and churned drivers. Stale
requires a historical population that excludes drivers not yet observed by each date.

## Decision

MAD means a fixed trailing 30-day active-driver count, not a calendar-month count.
For reporting date D, current activity is D-29..D and previous activity is D-30..D-1.
Activity and identity retain the network-wide credential definitions in ADR 0010.

Publish semantic metrics without replacing existing names or changing physical grain:

- `mad`: alias of `active_drivers_30d`.
- `mad_new`: alias of `new_drivers`, first observed on D, as explicitly chosen by the metric owner.
- `mad_retained`: alias of `retained_drivers_30d`, active in both windows.
- `mad_resurrected`: alias of `resurrected_drivers_30d`, active only in the current window and first observed before D.
- `mad_churned`: alias of `churned_drivers_30d`, active only in the previous window.
- `mad_stale`: observed by D, active in neither window.

Add `drivers_observed_to_date` as an all-time cumulative semantic metric over
`known_drivers_count`, using first_seen_ts and the same unknown-marker exclusions as
`new_drivers`. No trailing window or calendar reset applies. This population includes
only first-seen dates on or before D, never future acquisitions.

The existing 31-day union helper covers both active windows, so derive:

- stale = drivers observed to date - 31-day union
- MAD = new + retained + resurrected
- drivers observed to date = new + retained + resurrected + churned + stale

All five categories are non-negative counts and form a partition of observed drivers
as of each day. Churned and stale are outside MAD. Stack the three active categories
for MAD, or all five for the whole historical driver population. Never stack MAD itself
with its component categories. A separate positive/negative growth-flow chart is a
different presentation, not this five-part population stack.

Require metric_time__day and completed, fully ingested dates with aligned first-seen
and activity history. Preserve the lookback by filtering metric_time, not activity dates.
The prehistory, source completeness, credential identity, late-arrival, and retraction
limitations from ADRs 0010 and 0011 continue to apply. No dimension last_seen_ts is used
to reconstruct historical inactivity, and no dense driver-day state table is created.

## Alternatives considered

- Count all drivers acquired in the trailing 30 days as New: the metric owner chose
  daily entrants. Trailing acquisitions overlap the existing retained set and would
  require different category definitions.
- Use today's dimension row count as the historical population: leaks future drivers
  into earlier stale counts.
- Define stale as all drivers outside MAD: includes churned and breaks exclusivity.
- Store inactive driver-days: unnecessary for count-only set arithmetic.

## Consequences

A driver first seen five days ago is retained. A driver returning on D after activity
on D-30 is retained; a driver returning after last activity before D-30 is resurrected.
Churned drivers become stale the next day without a return. These distinctions arise
from comparing overlapping windows shifted by one day.

Five-way lifecycle counts are daily snapshots, not additive over dates or defined at
coarser grains. Current driver attributes remain Type 1. Historical processing must
keep first-seen acquisition and sparse activity coverage aligned. Synthetic tests cover
boundary returns, repeated activity, recent acquisitions, future drivers, empty active
sets, and dates before all known drivers; semantic warehouse validation checks planning.
