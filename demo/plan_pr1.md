# Stage 1 Plan (MVP Baseline)

**Goal:** Test whether the curated project context still drives correct chat behavior — not the LLM itself, not the chat product, not RAG. Catch regressions when [`agent_instructions.md`](demo/chat-bi/agent_instructions.md), [`RULES.md`](demo/chat-bi/RULES.md), [`nao_config.yaml`](demo/chat-bi/nao_config.yaml), [`semantic_models.yml`](models/semantic/semantic_models.yml), or [`marts.yml`](models/marts/marts.yml) change.

## Scope

- Add 2–3 eval test cases in `demo/chat-bi/tests/*.yml`
- Run expanded `nao test`
- Save outputs and build mini analysis table (`demo/chat-bi/tests/analysis/stage1_analysis.csv`)
- Ensure outputs are saved via Docker volume (no manual copy)
- Perform baseline vs expanded comparison (baseline = existing [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml) run)
- Send short update with findings

## Done Criteria

- `>=3` test files total (including existing [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml))
- 1 expanded run completed
- `results_*.json` retained per storage policy (file in agreed repo path, or path/link to external artifact recorded)
- Docker volume confirmed working (outputs reachable on host without `docker cp`)
- mini analysis table (`demo/chat-bi/tests/analysis/stage1_analysis.csv`) filled for all tests in run
- mini analysis table includes `failure_reason` for failed cases
- baseline metrics recorded (accuracy / cost / time)
- delta metrics captured (baseline vs expanded)
- short status note in the PR (or agreed team channel)
- storage decision documented for this run

## Mini Analysis Table (Stage 1)

Columns: `question`, `actual`, `expected` (optional), `status` (nao: `pass`/`fail`), `semantic_label` (`correct`/`partial`/`incorrect`), `failure_reason` (required if fail), `cost`, `execution_time`.

**Note:** `status` and `semantic_label` are independent layers — `status` is factual (nao harness), `semantic_label` is human review (rubric: see **Open decisions (merge)**).

## Methodology Note

- **`nao test`** — current **runtime** and **factual** baseline on the demo stack (DuckDB + chat-bi).
- **Factual layer** — `nao test` + SQL reference (data correctness).
- **Semantic layer (Stage 1)** — lightweight manual label (`semantic_label`) and `failure_reason`.
- **Future direction** — optional automation using tools like [deepeval](https://github.com/confident-ai/deepeval) in Stage 2+.

## Stage 1 Boundary and Next Stages

### Out of scope for Stage 1

- Full integration of the **deepeval** package into the demo runtime or CI (unless explicitly approved later).
- Making Answer Relevancy (or any deepeval metric) a required automated merge gate in Stage 1.
- Any automation that belongs to Stage 2+.

### Stage 2+ direction (placeholder)

- **Stage 2 (example):**

  - **Golden dataset** — single-turn; 10–12 entries; `question_id`, `user_input`, `reference_answer`, `reference_contexts` (or `source_refs`), optional `human_explanation`.
  - **`reference_contexts` meaning** — evidence/source pointers (e.g. `RULES.md`, `semantic_models.yml`, `marts.yml`) used for traceability and review; **not** extra context injected into model prompts.
  - **G-Eval rubrics** — Terminology (no `session`; source: [`RULES.md`](demo/chat-bi/RULES.md)), Rate Format (%, pp), Metric Validity (only metrics defined in [`semantic_models.yml`](models/semantic/semantic_models.yml)), Completeness vs expected output — aim for at least one custom metric.
  - **Judge** — wire automated evaluator (e.g. Claude Haiku via `DeepEvalBaseLLM`).
  - **`run_evals.py`** — load golden dataset → call nao FastAPI `localhost:8005` → write results under `evals/results/`.
  - **Standardize fields** — `semantic_metric`, `semantic_score`, `semantic_threshold`, `semantic_pass`, `semantic_reason`, `judge_model`.
  - **Optional CI.**
  - **Plan doc** — `plan_pr2.md` on branch `chat-evals-stabilization` (after Stage 1 merge).

- **Stage 3 (example):**

  - **Streamlit viewer** — color-coded summary (questions × rubrics), drill-down per row (actual vs expected + reason per rubric), aggregate trends per rubric across runs.
  - **Chat replays (optional source)** — use nao chat replay storage as a read-only source of candidate eval cases; sanitize/anonymize before dataset inclusion.
  - **Long-term storage** of eval history.
  - **Stricter org-wide gates.**
  - **Plan doc** — `plan_pr3.md` on branch `chat-evals-analytics` (after Stage 2 merge).

## Test Design Constraints

**Rules:** [`demo/chat-bi/RULES.md`](demo/chat-bi/RULES.md), [`demo/chat-bi/agent_instructions.md`](demo/chat-bi/agent_instructions.md), [`demo/chat-bi/nao_config.yaml`](demo/chat-bi/nao_config.yaml) — DuckDB only, no schema introspection, only `fact_*`/`dim_*` tables (`analytics.ANALYTICS.<table>`), default time window last 7 days.

**SQL:** reference `sql:` must use real columns from [`models/marts/marts.yml`](models/marts/marts.yml) and only metrics defined in [`models/semantic/semantic_models.yml`](models/semantic/semantic_models.yml).

**Narrative:** use `charge attempt`, `transaction`, `visit` — never `session`. Presentation rules (metrics at a glance, % format) apply to answer quality evaluation, not to the `sql:` block.

**No extra context in tests:** do not inject additional context chunks into test prompts — tests rely only on the system context already configured in nao (`agent_instructions.md`, `RULES.md`, etc.). This is intentional: we test the curated context, not a retrieval layer.

## PR (Stage 1 only)

**PR title:**

`Stage 1 MVP: initial eval set + expanded baseline run`

**PR should include:**

- new eval tests in `demo/chat-bi/tests/*.yml`
- expanded run outputs/artifacts (`results_*.json` or external artifact links)
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
- storage outcome documented (Q1–Q3 in **Open decisions (merge)**); artifact paths: container `/app/kwwhat/tests/outputs/`, repo `demo/chat-bi/tests/outputs/` or external (per agreed policy)
- review note: `failure_reason` is filled for failed cases (`status=fail`)

## Execution Order

1. Add tests (`demo/chat-bi/tests/*.yml`)
2. Run expanded `nao test`
3. Save/retain `results_*.json` according to agreed storage policy
4. Fill mini analysis table (include `question`, `actual`, optional `expected`, `status`, `semantic_label`, `failure_reason`, `cost`, `execution_time`)
5. Capture baseline vs expanded delta (accuracy / cost / time) and include a short summary of top 1–2 failure patterns
6. Commit implementation work using one PR/branch approach consistently for this repo
7. Post a short PR update and close items in **Open decisions (merge)**.

## Open decisions (merge)

Document the outcomes below in the PR (description or comments) before merge. They are **merge criteria**, not a prerequisite for local work: tests, `nao test` runs, and analysis drafts can proceed in parallel.

**Storage decisions**

- **Q1 (storage location)** — in-repo vs external for raw `results_*.json`.
  - **Proposed default:** external (do not commit raw JSON).
- **Q2 (external storage mode)** — preferred external option (shared folder / drive / artifact storage / PR-attached artifact reference).
  - **Proposed default:** keep file/artifact outside repo and leave path/link or short artifact note in PR.
- **Q3 (ignore rules)** — confirm `.gitignore` updates that match Q1–Q2.
  - **Proposed default:** add `demo/chat-bi/tests/outputs/` and `.DS_Store`.

**Storage note:** Q1–Q3 defaults above can be applied for Stage 1 to avoid blocking; mark final owner confirmation in PR comments/description.

**Policy decisions**

- **Semantic rubric (Stage 1)** — confirm `semantic_label` values and concise rubric.
  - **Proposed default:** `correct` = answer is accurate and complete; `partial` = correct conclusion but imprecise numbers or incomplete; `incorrect` = factual error or hallucination.
- **Scope boundary** — confirm automation (`run_evals.py`, Streamlit, automated judge metrics) is Stage 2+ and not required for Stage 1 merge.
  - **Proposed default:** yes, all automation is Stage 2+.

## Post-Stage 1 Calibration

- acceptable cost per run
- acceptable `execution_time`
- numeric/order tolerance thresholds
- priority among error categories (`hallucination` vs `wrong_filter` vs `sql_logic`)
- top-priority eval scenarios for next iteration
