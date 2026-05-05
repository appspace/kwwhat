# Stage 1 Plan (MVP Baseline)

**Goal:** Test whether the curated project context still drives correct chat behavior — not the LLM itself, not the chat product, not RAG. Catch regressions when [`agent_instructions.md`](demo/chat-bi/agent_instructions.md), [`RULES.md`](demo/chat-bi/RULES.md), [`nao_config.yaml`](demo/chat-bi/nao_config.yaml), [`semantic_models.yml`](models/semantic/semantic_models.yml), or [`marts.yml`](models/marts/marts.yml) change.

## Scope

- Add 2–3 SQL test cases in `demo/chat-bi/tests/*.yml`
- Run expanded `nao test`
- Save outputs and build mini analysis table (`demo/chat-bi/tests/analysis/stage1_analysis.csv`)
- Ensure outputs are saved via Docker volume (no manual copy)
- Perform baseline vs expanded comparison (baseline = existing [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml) run)
- Send short update with findings

## Done Criteria

- `>=3` test files total (including existing [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml))
- 1 expanded run completed
- `results_*.json` retained following nao's local JSON output pattern (reachable via Docker volume)
- Docker volume confirmed working (outputs reachable on host without `docker cp`)
- mini analysis table (`demo/chat-bi/tests/analysis/stage1_analysis.csv`) filled for all tests in run
- mini analysis table includes `failure_reason` for failed cases
- Stage 1 test case format agreed (baseline: existing [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml) structure)
- baseline metrics recorded (accuracy / cost / time)
- delta metrics captured (baseline vs expanded)
- short status note in the PR (or agreed team channel)
- storage decision documented for this run

## Mini Analysis Table (Stage 1)

Columns: `question`, `actual`, `expected` (optional), `status` (nao: `pass`/`fail`), `semantic_label` (`correct`/`partial`/`incorrect`), `failure_reason` (required if fail), `cost`, `execution_time`.

**Note:** `status` and `semantic_label` are independent layers — `status` is factual (nao harness), `semantic_label` is human review (rubric: see **Alignment and remaining checks (merge)**).

## Methodology Note

- **`nao test`** — current **runtime** and **factual** baseline on the demo stack (DuckDB + chat-bi).
- **Factual layer** — `nao test` + SQL reference (data correctness).
- **Semantic layer (Stage 1)** — lightweight manual label (`semantic_label`) and `failure_reason`; no automated judge in this PR.
- **Future direction** — native rubric/context eval support in `nao test` via upstream nao issue/contribution; not a Stage 1 blocker.

## Stage 1 Boundary and Next Stages

### Out of scope for Stage 1

- Full integration of the **deepeval** package into the demo runtime or CI (unless explicitly approved later).
- Making Answer Relevancy (or any deepeval metric) a required automated merge gate in Stage 1.
- Sidecar/post-processing G-eval automation scripts for Stage 1.
- Any automation that belongs to Stage 2+.

### Stage 2+ direction (placeholder)

- **Stage 2 (example):**

  - **Upstream nao direction** — native generic/context evals in `nao test` via upstream issue/contribution; this is a parallel track, not a Stage 1 blocker.
  - **Golden dataset** — single-turn; 10–12 entries; `question_id`, `user_input`, `reference_answer`, `reference_contexts` (or `source_refs`), optional `human_explanation`.
  - **`reference_contexts` meaning** — evidence/source pointers (e.g. `RULES.md`, `semantic_models.yml`, `marts.yml`) used for traceability and review; **not** extra context injected into model prompts.
  - **G-Eval rubrics** — Terminology (no `session`; source: [`RULES.md`](demo/chat-bi/RULES.md)), Rate Format (%, pp), Metric Validity (only metrics defined in [`semantic_models.yml`](models/semantic/semantic_models.yml)), Completeness vs expected output — aim for at least one custom metric.
  - **Automation path** — prefer native `nao test` support over temporary post-processing scripts; local Stage 2 prep can proceed while upstream direction is clarified.
  - **Standardize fields** — `semantic_metric`, `semantic_score`, `semantic_threshold`, `semantic_pass`, `semantic_reason`, `judge_model`.
  - **Optional CI.**
  - **Plan doc** — `plan_pr2.md` on branch `chat-evals-stabilization` (after Stage 1 merge).

- **Stage 3 (example):**

  - **Streamlit viewer** — color-coded summary (questions × rubrics), drill-down per row (actual vs expected + reason per rubric), aggregate trends per rubric across runs.
  - **Chat replays (optional source)** — use nao chat replay storage as a read-only source of candidate eval cases; sanitize/anonymize before dataset inclusion.
  - **Long-term storage** of eval history.
  - **Stricter org-wide gates.**
  - **Plan doc** — `plan_pr3.md` on branch `chat-evals-analytics` (after Stage 2 merge).

### Visualization notes (non-blocking)

Visualization is available as a future presentation layer, but it is **not required for this PR**.

- **Stage 1:** no separate dashboard deliverable; use run artifacts + mini analysis table (`demo/chat-bi/tests/analysis/stage1_analysis.csv`) in PR updates.
- **Stage 2:** keep visualization lightweight if useful (tables/recaps) while the eval mechanics and result format stabilize.
- **Stage 3:** primary visualization layer can be **Streamlit** for eval results (summary, drill-down, reasons, trends).
- **Out of scope for now:** standalone BI dashboard track (Power BI/Metabase on DuckDB) to avoid duplicate effort.
- **Optional later:** revisit Tableau Public only if there is clear value in extending existing WIP.

## Test Design Constraints

**Rules:** [`demo/chat-bi/RULES.md`](demo/chat-bi/RULES.md), [`demo/chat-bi/agent_instructions.md`](demo/chat-bi/agent_instructions.md), [`demo/chat-bi/nao_config.yaml`](demo/chat-bi/nao_config.yaml) — DuckDB only, no schema introspection, only `fact_*`/`dim_*` tables (`analytics.ANALYTICS.<table>`), default time window last 7 days.

**SQL:** reference `sql:` must use real columns from [`models/marts/marts.yml`](models/marts/marts.yml) and only metrics defined in [`models/semantic/semantic_models.yml`](models/semantic/semantic_models.yml).

**Narrative:** use `charge attempt`, `transaction`, `visit` — never `session`. Presentation rules (metrics at a glance, % format) apply to answer quality evaluation, not to the `sql:` block.

**No extra context in tests:** do not inject additional context chunks into test prompts — tests rely only on the system context already configured in nao (`agent_instructions.md`, `RULES.md`, etc.). This is intentional: we test the curated context, not a retrieval layer.

## PR (Stage 1 only)

**PR title:**

`Stage 1 MVP: initial eval set + expanded baseline run`

**PR should include:**

- new SQL tests in `demo/chat-bi/tests/*.yml`
- expanded run outputs/artifacts (`results_*.json` from local nao output flow)
- mini analysis table covering all tests from the expanded run
- evaluation approach:
  - SQL as factual reference layer
  - LLM answer as semantic quality layer
- link/reference to baseline run
- delta summary: baseline vs expanded
- short summary:
  - pass/fail
  - cost/time
  - top 1–2 failure patterns
  - next actions
- storage outcome documented; artifact paths: container `/app/kwwhat/tests/outputs/`, repo/Docker volume `demo/chat-bi/tests/outputs/`
- review note: `failure_reason` is filled for failed cases (`status=fail`)

## Execution Order

1. Add tests (`demo/chat-bi/tests/*.yml`)
2. Run expanded `nao test`
3. Save/retain `results_*.json` following nao's local JSON output pattern
4. Fill mini analysis table (include `question`, `actual`, optional `expected`, `status`, `semantic_label`, `failure_reason`, `cost`, `execution_time`)
5. Capture baseline vs expanded delta (accuracy / cost / time) and include a short summary of top 1–2 failure patterns
6. Commit implementation work using one PR/branch approach consistently for this repo
7. Post a short PR update and close items in **Alignment and remaining checks (merge)**.

## Alignment and remaining checks (merge)

Document the outcomes below in the PR (description or comments) before merge. They are **merge checks**, not a prerequisite for local work: tests, `nao test` runs, and analysis drafts can proceed in parallel.

**Aligned decisions**

- **Stage 1 scope** — proceed with SQL tests + manual `semantic_label`; no G-eval automation in this PR.
- **Storage** — follow nao's existing local JSON output pattern (`results_*.json` in Docker volume / `tests/outputs` flow).
- **Test case naming** — call Stage 1 YAML cases “SQL tests” for clarity.
- **Test case format** — use existing [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml) structure as Stage 1 baseline.
- **Upstream nao issue** — native context/rubric eval support is a parallel Stage 2 input, not a Stage 1 blocker.

**Remaining merge checks**

- **Semantic rubric (Stage 1)** — confirm `semantic_label` values and concise rubric.
  - **Proposed default:** `correct` = answer is accurate and complete; `partial` = correct conclusion but imprecise numbers or incomplete; `incorrect` = factual error or hallucination.
- **Outputs/ignore rules** — ensure generated local outputs are not accidentally committed unless explicitly selected as a small analysis artifact.

## Post-Stage 1 Calibration

- acceptable cost per run
- acceptable `execution_time`
- numeric/order tolerance thresholds
- priority among error categories (`hallucination` vs `wrong_filter` vs `sql_logic`)
- top-priority eval scenarios for next iteration
