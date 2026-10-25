# Chat Evals Plan: Stage 2 Stabilization

**Branch:** `chat-evals-stabilization`
**Status:** Stage 1 merged in [#86](https://github.com/appspace/kwwhat/pull/86) on 2026-05-07. Stage 2 builds from that baseline.

---

## Decision

Stage 2 proceeds locally in kwwhat now. Upstream nao eval support remains a parallel design track and does not block this PR.

This plan does not implement either nao proposal in [`correctness_plan.md`](../correctness_plan.md) or [`rag_triad_plan.MD`](../rag_triad_plan.MD). Those documents stay as upstream design inputs for nao issue #727. Stage 2 focuses on the artifacts kwwhat can own today: golden cases, rubrics, result fields, and lightweight analysis.

---

## Goal

Strengthen repeatable Chat BI evals for **context-quality regressions**.

Stage 2 is not a general model benchmark. It asks whether changes to curated project context, such as [`RULES.md`](chat-bi/RULES.md), [`agent_instructions.md`](chat-bi/agent_instructions.md), [`nao_config.yaml`](chat-bi/nao_config.yaml), [`semantic_models.yml`](../models/semantic/semantic_models.yml), or [`marts.yml`](../models/marts/marts.yml), make Chat BI answers better or worse.

The factual layer remains `nao test` plus SQL assertions. Stage 2 adds a semantic layer for answer quality: terminology, metric validity, formatting, completeness, faithfulness to configured context, and reviewer traceability.

Stage 2 follows a **targeted, composite eval approach**: SQL/programmatic checks cover factual assertions; LLM-as-judge (or human labels first) covers semantic quality; human review calibrates ambiguous cases. Evals are single-turn, reference-based, and end-to-end — the score signals **context quality**, not general model quality.

---

## Stage 2 Deliverables

1. **Golden dataset**
   - Single-turn eval cases.
   - **At least 5** reviewed cases for merge (see Acceptance Criteria); grow toward 10-12 after Stage 2.
   - Store under `demo/chat-bi/tests/evals/`.
   - Reference answers are reviewed like code.

2. **Semantic rubrics**
   - Define targeted rubrics for known Chat BI failure modes.
   - At least **3 categories** represented in the dataset and documented in `evals/rubrics.md` with pass/fail criteria and examples.
   - Rubrics may later be run through DeepEval, Ragas-style tooling, or a small in-house sidecar, but no framework is required as a Stage 2 merge gate.

3. **Stable result schema**
   - Standardize semantic result fields so runs can be compared over time.
   - Keep SQL harness status separate from semantic answer quality.

4. **`results_summary.py`**
   - Generate a compact CSV analysis from `results_*.json`.
   - Generate a short markdown summary for PR review.
   - Preserve the Stage 1 convention of committing selected analysis artifacts, not raw run noise.

5. **Calibration notes**
   - Track cost, latency, model, flakiness, and ambiguous judge behavior.
   - Use human review for the first runs before treating semantic scores as gates.
   - Record `judge_model` separately; when the judge is the same model as the agent, treat scores as an upper-bound signal until compared with an independent judge.

---

## Acceptance Criteria

Stage 2 is ready to merge when:

- `demo/chat-bi/tests/evals/` contains **at least 5** reviewed golden cases, including:
  - 3 SQL-linked cases from Stage 1 (`total_ports`, `decommissioned_ports_check`, `network_reliability_uptime`);
  - 2 semantic-only cases (`metric_validity`, `terminology`).
- Each case has required fields: `question_id`, `category`, `eval_type`, `user_input`, `reference_answer`, `primary_context`, `reference_contexts`, and `human_explanation`.
- At least **3 rubric categories** are represented across the dataset, such as `metric_validity`, `terminology`, and `rate_format`.
- At least **one rubric doc** exists, for example `demo/chat-bi/tests/evals/rubrics.md`, with pass/fail criteria and at least one pass and one fail example per represented category.
- `results_summary.py` runs on existing Stage 1 `results_*.json` output and produces:
  - one CSV under `demo/chat-bi/tests/analysis/`;
  - one markdown summary under `demo/chat-bi/tests/analysis/`.
- The summary includes measurable totals: pass count, fail count, total cost, total tokens, total execution time, and top failure reasons.
- SQL harness `status` and semantic fields remain separate in the summary output.
- No raw `results_*.json` files are staged or committed.
- The PR adds no required dependency on DeepEval, Ragas, or Latitude.
- The PR requires no upstream nao changes or new backend endpoints.

---

## Golden Dataset Shape

Proposed first local format:

```yaml
- question_id: q004
  category: metric_validity
  eval_type: llm_judge
  user_input: "What is the charge point availability index?"
  reference_answer: |
    The metric "charge point availability index" is not defined in the semantic model.
    The closest available metric is uptime. Would you like that instead?
  primary_context: models/semantic/semantic_models.yml
  reference_contexts:
    - file: models/semantic/semantic_models.yml
      hint: only metrics defined here are valid
    - file: demo/chat-bi/RULES.md
      hint: do not invent undefined metrics
  human_explanation: The assistant must decline the undefined metric and redirect to uptime.
```

Field meanings:

| Field | Purpose |
|---|---|
| `question_id` | Stable case identifier. |
| `category` | Rubric group, such as `metric_validity` or `terminology`. |
| `eval_type` | `sql`, `llm_judge`, or future mixed type. |
| `user_input` | The prompt sent to Chat BI. |
| `reference_answer` | Reviewed target answer: intent, facts, and required framing. |
| `primary_context` | Main reviewer evidence file. |
| `reference_contexts` | Evidence pointers for review and calibration. These are not injected into the assistant prompt. |
| `human_explanation` | Short note explaining the failure mode the case is meant to catch. |

`reference_contexts` are traceability pointers, not extra prompt chunks. The eval should exercise the same curated nao context a user would rely on in the demo.

`primary_context` should point to the file a reviewer uses to **verify** the answer (for example `semantic_models.yml`). Put the rule under test in `reference_contexts` when it differs (for example `RULES.md`).

---

## Future Compatibility

The Stage 2 golden format should stay compatible with future native eval support. One local artifact can serve the Stage 2 prototype, the upstream design discussion, and the Stage 3 history schema without requiring upstream nao changes in this PR.

| kwwhat (Stage 2) | nao #727 (upstream) | nao test (today) | Purpose |
|---|---|---|---|
| `user_input` | `input` | `prompt` | the input |
| `reference_answer` | `expected_output` | — | gold standard for the judge |
| `category` + `human_explanation` | `context_hint` | — | which rule/context is under test |
| `eval_type: sql` + `sql:` | SQL eval (unchanged) | `sql` | deterministic factual layer |
| `primary_context` / `reference_contexts` | richer `context_hint` | — | reviewer traceability — **not injected** |
| `semantic_score` / `semantic_pass` / `semantic_reason` / `judge_model` | stable judge output fields | — | result record |

---

## Initial Case Set

Seed Stage 2 from existing Stage 1 coverage plus two semantic-only cases:

| question_id | Case | Source | eval_type | Primary rubric |
|---|---|---|---|---|
| `q001` | total ports | [`total_ports.yml`](chat-bi/tests/total_ports.yml) | `sql` | factual baseline |
| `q002` | decommissioned ports | [`decommissioned_ports_check.yml`](chat-bi/tests/decommissioned_ports_check.yml) | `sql` | factual baseline + concise answer |
| `q003` | overall uptime | [`network_reliability_uptime.yml`](chat-bi/tests/network_reliability_uptime.yml) | `sql` | `rate_format` + full-history wording |
| `q004` | undefined metric | new golden case | `llm_judge` | `metric_validity` |
| `q005` | `session` terminology | new golden case | `llm_judge` | `terminology` |

`lately_snapshot.yml` stays in the SQL harness but is deferred from the first golden set until namespace/catalog stability is confirmed (Stage 1 showed `RAW` binder drift).

When SQL aggregates over all available data, the prompt must explicitly say "full history"; otherwise the default last-7-days rule applies. Align [`network_reliability_uptime.yml`](chat-bi/tests/network_reliability_uptime.yml) prompt wording when building `q003`.

---

## Rubrics

Initial rubric categories:

| Rubric | Checks |
|---|---|
| `metric_validity` | The answer only uses metrics defined in `semantic_models.yml`; undefined metrics are declined and redirected. |
| `terminology` | The answer uses kwwhat vocabulary: `charge attempt`, `transaction`, `visit`; never `session` for the modeled EV charging concept. |
| `rate_format` | Percentages and percentage-point changes are formatted clearly and consistently. |
| `faithfulness` | The answer does not add unsupported claims or misleading narrative beyond SQL results and curated context. |
| `completeness` | The answer covers the requested scope at the expected level of detail. |

### Rubric priority for v1

For curated-context BI chat, not classic RAG retrieval:

| Rubric | Stage 2 priority | Notes |
|---|---|---|
| `faithfulness` | **Primary** | no invented metrics, wrong terminology, misleading narrative on correct SQL |
| `metric_validity` | High | often a faithfulness sub-case |
| `terminology` | High | kwwhat vocabulary enforcement |
| `rate_format` | Secondary | formatting on rate/percentage answers |
| `completeness` | Secondary | after factual + faithfulness |
| Context relevance | Skip v1 | context is curated, not retrieved |

Citation inspectability folds into `faithfulness` in v1. Promote it to a separate rubric only if `traceability_label` failure rate is ≥10–15% after calibration on 10–20 cases.

For Stage 2, rubrics can start as documented criteria plus human labels. An automated LLM-as-judge sidecar is optional after the rubrics and dataset shape are stable.

---

## Result Schema

Keep deterministic harness status and semantic judgment as separate layers.

Existing / factual fields:

| Field | Description |
|---|---|
| `run_id` | Unique run identifier. |
| `timestamp` | Run timestamp. |
| `test_name` | YAML test name. |
| `question` | Input prompt. |
| `expected` | Reference output from SQL or rubric. |
| `actual` | LLM output. |
| `status` | SQL harness pass/fail status. |
| `tokens` | Token usage. |
| `cost` | API cost. |
| `execution_time` | Latency in seconds. |
| `error_type` | Failure category. |
| `model` | Agent model version. |
| `failure_reason` | Manual or derived failure reason. |
| `notes` | Optional reviewer notes. |

Stage 2 semantic fields:

| Field | Description |
|---|---|
| `semantic_metric` | Rubric or judge metric name. |
| `semantic_score` | Semantic score when an automated or manual score exists. |
| `semantic_threshold` | Threshold used for the metric, if applicable. |
| `semantic_pass` | Semantic pass/fail result. |
| `semantic_reason` | Short explanation for the semantic result. |
| `semantic_label` | Human label such as `correct`, `partial`, or `incorrect`. |
| `judge_model` | Judge model version, recorded separately from the agent model. |
| `traceability_label` | Manual inspectability label for evidence quality. |

`status` remains the `nao test` / SQL harness result. `semantic_pass` and `semantic_label` describe answer quality and may disagree with `status`.

`traceability_label` is manual in Stage 2:

| Label | Meaning |
|---|---|
| `good` | Reviewer can verify the claim from named metric, table, rule, or context. |
| `weak` | Source is vague or incomplete. |
| `incorrect` | Cited or implied source does not support the claim. |
| `missing` | Important numbers or claims have no inspectable support. |

### `failure_reason` values (manual in Stage 2)

Use alongside `semantic_label` when reviewing runs:

- `invented_metric`
- `wrong_terminology`
- `misleading_narrative`
- `wrong_rate_format`
- `incomplete_answer`
- `missing_citation`
- `wrong_citation`
- `sql_pass_semantic_fail` — SQL harness passed but answer quality failed

---

## File Layout

```text
demo/chat-bi/tests/
  evals/
    golden_dataset.yml      # reviewed cases (YAML list)
    rubrics.md              # pass/fail criteria and examples
  outputs/
    results_*.json          # local only — gitignored
  analysis/
    stage2_analysis.csv     # committed summary artifact
    stage2_delta_summary.md # committed PR review artifact
    calibration_notes.md  # cost, flake, ambiguous cases
demo/
  results_summary.py        # reads results_*.json → analysis artifacts
```

---

## Workflow

1. `dbt seed && dbt run --full-refresh` when incremental state may affect outputs.
2. Run the SQL harness: `nao test` (Docker demo or local).
3. Treat `results_*.json` as read-only run output. Use it to inspect actual answers and errors.
4. Record manual `semantic_label`, `traceability_label`, and `failure_reason` in `stage2_analysis.csv` and `calibration_notes.md`, not in raw JSON files.
5. Cross-check against `evals/golden_dataset.yml` reference answers.
6. `python demo/results_summary.py` → CSV + markdown under `tests/analysis/`.
7. After the first baseline runs, promote failures that survive human review into `golden_dataset.yml` with a reviewed `reference_answer` and `human_explanation`.
8. Commit golden dataset, rubrics, and analysis artifacts — **not** raw `results_*.json`.

---

## Automation

`results_summary.py` implements the summary step in the workflow and should stay lightweight:

- read one or more `demo/chat-bi/tests/outputs/results_*.json` files;
- write an analysis CSV under `demo/chat-bi/tests/analysis/`;
- write a short markdown delta summary for PR review;
- summarize pass rate, semantic labels, top failure reasons, total cost, total tokens, and execution time;
- avoid committing raw `results_*.json` by default.

The first version can support Stage 1-style data. Semantic fields can be added as soon as the golden dataset and manual labels exist.

---

## Long-Term Testing Notes

Keep these as future-facing calibration practices, not Stage 2 merge gates:

- Treat same-model judge scores as an upper-bound signal until an independent judge run is compared.
- Promote reviewed real failures into `golden_dataset.yml` so the dataset grows from observed regressions, not only imagined cases.
- After 2-3 stable baseline runs, use selected context changes to learn which rules or semantic-model entries are load-bearing, redundant, or risky.

---

## Out of Scope for Stage 2

- Upstream nao implementation for issue #727.
- A required DeepEval, Ragas, or Latitude dependency.
- RAG triad runtime context capture or a new nao backend endpoint.
- Required automated LLM judge gate before rubrics are calibrated.
- CI blocking gate.
- Streamlit viewer or standalone analytics dashboard.
- Long-term eval history store.
- Chat replay ingestion.
- MCP or external agent distribution.
- Full context-ablation runner (baseline vs intervention). Methodology only; first manual ablation pass may happen after Stage 2 merge.

---

## Stage 3 Direction

Stage 3 starts after Stage 2 has a stable dataset and result schema.

Likely Stage 3 work:

- append-only eval history;
- Streamlit or lightweight viewer;
- trends across runs and rubrics;
- sanitized chat replay candidates;
- recurring-failure monitors;
- lightweight context ablation on selected golden cases after 2-3 baseline runs, classifying context elements as load-bearing, redundant, or risky;
- stricter gates once thresholds, cost, and flake are understood.

---

## Stage 1 Baseline

Stage 1 established the factual regression layer:

- `nao test` plus SQL assertions is the factual reference layer.
- Manual `semantic_label` and `failure_reason` are lightweight semantic annotations.
- `status` and `semantic_label` are independent.
- Raw `results_*.json` should not be bulk-committed; selected analysis artifacts are enough.
- Docker volume mapping makes test outputs available at `demo/chat-bi/tests/outputs/`.

Stage 1 delivered SQL tests for `total_ports`, `decommissioned_ports_check`, `lately_snapshot`, and `network_reliability_uptime`, plus analysis artifacts under `demo/chat-bi/tests/analysis/`.

---

## Test Design Constraints

**Rules:** Use DuckDB only, no schema introspection, and only `fact_*` / `dim_*` tables through `analytics.ANALYTICS.<table>`.

**SQL:** `sql:` must use real columns from [`marts.yml`](../models/marts/marts.yml) and only metrics defined in [`semantic_models.yml`](../models/semantic/semantic_models.yml).

**Time windows:** If expected SQL has no date filter and aggregates over all available data, the prompt must explicitly ask for "full history"; otherwise the default last-7-days rule applies.

**Reproducibility:** Use `dbt run --full-refresh` for demo setup when previous incremental state could affect eval outputs.

**Narrative:** Use `charge attempt`, `transaction`, and `visit`; do not use `session` for the modeled EV charging concept.

**Prompting:** Do not inject extra context into eval prompts. Tests should exercise curated nao context through the normal demo setup.
