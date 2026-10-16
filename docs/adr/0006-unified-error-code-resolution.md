# 0006. Unified error-code resolution for downtime reasons

- Status: Accepted
- Date: 2026-10-01
- Related: #166, `dim_error_codes`, `fact_downtime_daily`, `int_faulted_outages`

## Context

OCPP 1.6 `errorCode` is often generic: a charger may send `OtherError` with a vendor code
(e.g. ChargeX `CX003`, meaning HighTemperature). Earlier, `fact_downtime_daily` exposed raw
`latest_error_code_name`, `latest_error_code` and `latest_taxonomy` columns, so consumers had to
decode faults themselves and different faults on the same day collapsed into one row.

## Decision

- `dim_error_codes` is a single multi-taxonomy dimension (OCPP 1.6 plus vendor dictionaries such
  as ChargeX MREC). Adding a taxonomy means adding a seed, not columns. Vendor-specific attributes
  live in outrigger dimensions (e.g. `dim_chargex_mrec_attributes`).
- Each outage resolves to one code: the vendor code when reported and known, otherwise the
  OCPP 1.6 row for the reported `errorCode`.
- `fact_downtime_daily` splits `downtime_type` (FAULTED, OFFLINE) from `reason`, the resolved
  `error_code_name`. Special values: `NoHeartbeat` for OFFLINE, `NoError` when no code was
  reported, `UnknownError` when a reported code is not in the dimension.
- Grain becomes `date_id + charger_id + port_id + downtime_type + reason`.

## Alternatives considered

- **Keep raw code columns on the fact.** Pushes decoding into every dashboard and makes
  `OtherError` the most common reason.
- **One dimension per taxonomy.** Every new vendor would need new columns and joins in facts.

## Consequences

- Downtime by reason is meaningful without extra joins.
- An outage whose code changes partway through is attributed wholly to its latest code.
- `latest_error_code_key` is looked up by joining the dimension, an accepted exception to
  [0003](0003-facts-generate-dimension-keys-in-place.md).
- Unknown vendor codes surface as `UnknownError`, signalling that a seed needs updating.
