# 0001. Record architecture decisions

- Status: Accepted
- Date: 2026-10-15

## Context

kwwhat encodes many decisions that change what its metrics mean: grain, key design,
visit grouping windows, error-code resolution, cross-warehouse patterns. The rules live in
`CLAUDE.md` and model docs, but the reasoning behind them (what else was considered, and
when to revisit) lives only in PR threads and people's heads. The project is also consumed by
LLM-driven tools and agents, which follow rules well but cannot recover intent that was never
written down.

## Decision

Record significant decisions as Architecture Decision Records in `docs/adr/`, one numbered
markdown file per decision, using [0000-template.md](0000-template.md).

- Write an ADR for any change that alters grain, a metric definition, a key strategy, or a
  project-wide convention.
- Open it with status `Proposed` in the same PR as the change; set `Accepted` when it merges.
- Accepted ADRs are not rewritten. To change a decision, add a new ADR and mark the old one
  `Superseded by NNNN`.
- `CLAUDE.md` states the rule (what to do). The ADR states the reason (why, and what lost).
- ADRs are published with the GitHub Pages site.

## Alternatives considered

- **Keep reasoning in `CLAUDE.md`.** It is loaded into every agent session, so long rationale
  there costs context and blurs rules with history.
- **Rely on PR descriptions.** Hard to find, not versioned with the code, and not linked to the
  current state of a decision.

## Consequences

- Reviewers and agents can check whether a change contradicts an accepted decision.
- Small extra effort per significant PR.
- Decisions made before this ADR are backfilled (0002 onwards) and dated when recorded.
