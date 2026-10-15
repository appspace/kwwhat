# 0004. Visit grouping windows: 30 minutes authenticated, 2 minutes unauthenticated

- Status: Accepted
- Date: 2026-10-15 (backfilled; decision predates this record)
- Related: `fact_visits`

## Context

A charge attempt is a technical event; a driver cares whether the trip ended in a charge. One
trip may include a failed plug-in and a retry, possibly on another port. Attempts must be grouped
into visits, but many attempts arrive without an `idTag` (e.g. plug-and-charge failures before
authorisation).

## Decision

1. If an unauthenticated attempt is followed on the same port within 2 minutes by an
   authenticated one, it inherits that `idTag`.
2. Authenticated attempts group by `location_id + idTag`, with gaps of at most 30 minutes.
3. Remaining unauthenticated attempts group by `location_id + charger_id + port_id`, with gaps of
   at most 2 minutes.

## Alternatives considered

- **One attempt per visit.** Overstates failures: a quick retry that succeeds counts as a failed
  visit.
- **Single window for all attempts.** A 30-minute window without a driver identity would merge
  different drivers who used the same port back to back.

## Consequences

- Visit success rate reflects driver outcomes, not protocol retries.
- The 30 and 2 minute thresholds are business assumptions. Changing them changes the visit
  metrics and needs a new ADR.
- Grouping logic is non-trivial and must stay covered by unit tests.
