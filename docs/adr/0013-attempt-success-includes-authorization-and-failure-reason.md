# 0013. Attempt success includes authorization, failures carry a reason, and attempts in progress are neutral

- Status: Proposed
- Date: 2026-11-21
- Related: [0014](0014-visit-rates-might-not-add-up-to-1.md), `fact_charge_attempts`, `fact_visits`,
  `models/semantic/semantic_models.yml`

## Context

`fact_charge_attempts.is_successful` was true when an attempt had a transaction, its next status after
Preparing was not `Faulted`, it stopped with `Local`, `Remote` or `EVDisconnected`, and it transferred more
than 0.1 kWh. Two gaps followed from that:

- **Authorization was not a criterion.** A transaction the central system rejected in StartTransaction.conf
  (`id_tag_status` `Blocked`, `Expired`, `Invalid` or `ConcurrentTx`) only failed because the charger then
  stopped it (`DeAuthorized`) before energy flowed. The rejection itself, the reason the driver couldn't
  charge, was not part of the definition.
- **A failed attempt didn't say why.** The flag was one boolean over four conditions. Attributing failures
  meant re-deriving the conditions from `transaction_id`, `next_status`, `transaction_stop_reason` and
  `energy_transferred_kwh`. The semantic model repeated the whole expression in its `is_successful`
  dimension, and exposed `transaction_stop_reason` and `next_status` but not `id_tag_status`, so a split of
  failures by authorization outcome wasn't available there at all.

## Decision

- Add authorization to the success criteria: an attempt whose `id_tag_status` is anything but `Accepted` is
  not successful. An unknown status (no id_tag) doesn't fail an attempt.
- Add `failure_reason` to `fact_charge_attempts`: the most specific criterion the attempt failed, and null
  when it succeeded. The reasons are checked in the order below. `NO_TRANSACTION` comes last because it is
  the least descriptive: it says only that no transaction started, so a fault or rejection that explains
  why takes precedence. The stop reason and energy checks apply only to attempts with a transaction.

  | `failure_reason`      | The attempt failed because                                                         |
  | --------------------- | ---------------------------------------------------------------------------------- |
  | `AUTH_REJECTED`       | the central system rejected the id_tag in StartTransaction.conf                    |
  | `FAULTED_AFTER`       | the connector's next status after Preparing was `Faulted`                          |
  | `INVALID_STOP_REASON` | it stopped with a reason other than `Local`, `Remote` or `EVDisconnected`, or none |
  | `LOW_KWH`             | energy transferred is missing or at most `success_energy_threshold_kwh`            |
  | `NO_TRANSACTION`      | the connector left Preparing without a transaction; nothing more specific applies  |

- Treat an attempt in progress as neutral: `is_successful` and `failure_reason` are both null, unless a
  rejected id_tag or a fault already failed it. An attempt is in progress while its transaction is open
  (started, no StopTransaction yet: the stop reason and energy are unknown), and while it has no transaction
  and the connector hasn't left Preparing (`next_status` null: a StartTransaction may still come). Once the
  connector reports its next status without a transaction, the transaction didn't happen, and the attempt
  fails as `NO_TRANSACTION`. Counting an attempt in progress as failed would be a guess. A visit takes its
  last attempt's outcome, so it is neutral too. What that means for the reliability rates is
  [0014](0014-visit-rates-might-not-add-up-to-1.md).
- Derive `is_successful` from `failure_reason`: false when it is set, null for a neutral attempt in progress,
  true otherwise. Tests check that the two agree and that only attempts in progress are null.
- In the semantic model, read `is_successful` from the column instead of repeating the expression, and add
  `failure_reason` and `id_tag_status` as dimensions of `charge_attempts`. Visits reach them through the
  `charge_attempt` entity (the visit's last attempt).

## Alternatives considered

- **One boolean per criterion** (`is_transaction_present`, `is_next_status_not_faulted`,
  `is_transaction_stop_reason_valid`, ...). Shows every condition an attempt failed, not just the first, but
  splitting failures by cause then needs a combination of five flags. One categorical column groups
  directly and reads as an answer.

## Consequences

- `is_successful` is nullable on `fact_charge_attempts` and `fact_visits`; its `not_null` tests are replaced by
  the consistency tests. Consumers that test `if is_successful` treat open as not successful; use `not
  is_successful` for failures.
- A StopTransaction that never arrives, or a connector that never reports a status after Preparing, keeps an
  attempt neutral indefinitely. Such attempts are visible as `is_successful` null with an old
  `charge_attempt_start_ts`.
- The rule depends on Preparing. An attempt captured from its StartTransaction alone has a transaction and is
  judged by it. A plug-in that left neither a Preparing nor a StartTransaction has no attempt row at all.
- `failure_reason` explains only the most specific failed criterion. An attempt rejected as `Expired` and
  stopped `DeAuthorized` at 0 kWh reports `AUTH_REJECTED`, not also `INVALID_STOP_REASON` and `LOW_KWH`.
- An OCPP 1.6 Authorize that the central system rejects carries no `connectorId`, so it can't be attached to
  an attempt. Those attempts report `NO_TRANSACTION` with a null `id_tag_status`, the same as a driver who
  left. Only rejections in StartTransaction.conf are `AUTH_REJECTED`. A plug-in that faults without starting a
  transaction reports `FAULTED_AFTER`, not `NO_TRANSACTION`.
- A null stop reason with a StopTransaction still fails as `INVALID_STOP_REASON`, as before. OCPP 1.6 allows
  omitting the reason when it is `Local`; whether to treat a missing reason as `Local` is a separate decision.
- The success criteria now live in one expression in `fact_charge_attempts`. A change to them has to update
  `failure_reason`'s accepted values and the documentation in `marts.yml` and the semantic model.
- On existing data, the authorization criterion changes no outcome where every rejected transaction was
  already stopped without energy. `fact_charge_attempts` gains a column; existing incremental tables pick it up
  through `on_schema_change: append_new_columns`, but old rows stay null until a full refresh.
