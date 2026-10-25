# Architecture Decision Records

Why kwwhat is modelled the way it is. Each record captures one decision, its context, the
alternatives considered, and the consequences. Rules to follow day to day live in
[CLAUDE.md](https://github.com/appspace/kwwhat/blob/main/CLAUDE.md); these records explain the reasons behind them.

## Adding an ADR

1. Copy [0000-template.md](0000-template.md) to the next free number, e.g. `0008-short-title.md`.
2. Set status `Proposed` and open it in the same PR as the change it describes.
3. When the PR merges, set status `Accepted` and add a row below.
4. To change an accepted decision, write a new ADR and mark the old one `Superseded by NNNN`.
   Do not rewrite accepted ADRs.

Write an ADR when a change alters grain, a metric definition, a key strategy, or a
project-wide convention.

## Index

| # | Decision | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-port-grain-for-reliability-metrics.md) | Port grain for reliability and utilisation metrics | Accepted |
| [0003](0003-facts-generate-dimension-keys-in-place.md) | Facts generate dimension keys in place; natural keys resolve in intermediate | Accepted |
| [0004](0004-visit-grouping-windows.md) | Visit grouping windows: 30 min authenticated, 2 min unauthenticated | Accepted |
| [0005](0005-cross-warehouse-compatibility.md) | Cross-warehouse compatibility through dispatched kwwhat macros | Accepted |
| [0006](0006-unified-error-code-resolution.md) | Unified error-code resolution for downtime reasons | Accepted |
| [0007](0007-energy-based-utilisation-denominator.md) | Rated power as the denominator for energy-based utilisation | Accepted |
| [0008](0008-warehouse-incremental-checkpoints.md) | Warehouse-resident checkpoints for incremental processing | Proposed |

