# Chat evals plan — Stage 2 (stabilization)

**Branch:** `chat-evals-stabilization`
**Status:** Stage 1 merged in [**#86**](https://github.com/appspace/kwwhat/pull/86) (2026-05-07) — that is the baseline we build from.

---

## Stage 2 — current focus

### Goal

Strengthen repeatable evals: golden dataset, rubrics, light automation, stable result format. No blocking on upstream nao.

### Scope

- **Golden dataset** — single-turn; ~10–12 entries; fields: `question_id`, `user_input`, `reference_answer`, `reference_contexts` (or `source_refs`), optional `human_explanation`.
  - `reference_contexts` = evidence pointers (`RULES.md`, `semantic_models.yml`, `marts.yml`) for traceability and review — **not** extra chunks injected into model prompts.
- **G-Eval rubrics** — e.g. Terminology (no `session`; source: [`RULES.md`](demo/chat-bi/RULES.md)), Rate Format (%, pp), Metric Validity (only metrics defined in [`semantic_models.yml`](models/semantic/semantic_models.yml)), Completeness vs expected output — aim for ≥1 custom rubric.
- **`results_summary.py`** — lightweight script to generate `stage1_analysis.csv` and `stage1_delta_summary.md` from `results_*.json`; first automation step in Stage 2.
- **Standardize result fields** — `semantic_metric`, `semantic_score`, `semantic_threshold`, `semantic_pass`, `semantic_reason`, `judge_model`.
- **Upstream nao direction** — native generic/context evals in `nao test` via upstream issue/contribution; **parallel track**, not a Stage 2 blocker; local prep proceeds independently.
- **Optional CI** — add gate once rubrics and flake are under control.
- **Plan doc** — this file (`plan_pr2.md`) on branch `chat-evals-stabilization`.

### Visualization in Stage 2

Keep lightweight: tables and short markdown recaps in PRs. No standalone dashboard deliverable yet.

### Post–Stage 1 calibration (carry into Stage 2 runs)

Tune with real runs and document outcomes in Stage 2 PRs:

- Acceptable **cost** and **execution_time** per run.
- Numeric / ordering **tolerance** thresholds.
- **Priority** among error categories (`hallucination` vs `wrong_filter` vs `sql_logic`).
- Top **eval scenarios** to grow first (e.g. partner support flows when ready).

---

## Stage 3 — direction (branch `chat-evals-analytics`, after Stage 2 merge)

- **Streamlit viewer** — color-coded summary (questions × rubrics), drill-down per row (actual vs expected + reason per rubric), aggregate trends per rubric across runs.
- **Chat replays (optional source)** — use nao chat replay storage as a read-only source of candidate eval cases; sanitize/anonymize before dataset inclusion.
- **Long-term storage** of eval history.
- **Stricter org-wide gates.**
- **Plan doc** — `plan_pr3.md` on branch `chat-evals-analytics` (after Stage 2 merge).

---

## Out of scope

- **deepeval** full integration into demo runtime or CI as a **required** merge gate — unless explicitly approved.
- **Sidecar/post-processing G-eval scripts** as a required Stage 2 gate before rubrics are stable.
- **Standalone BI dashboard** (Power BI / Metabase on DuckDB) — duplicate effort; revisit only with clear value.
- **Tableau Public** — optional later if portfolio case warrants it.
- **MCP / external agent distribution** — separate parallel track; not part of this eval roadmap.

---

## Stage 1 — completed reference

> Full execution checklists and PR alignment live in [**#86**](https://github.com/appspace/kwwhat/pull/86). This section is a compact record to orient Stage 2.

### Goal (achieved)

Test whether **curated project context** drives correct chat behavior — not the LLM product, not RAG — and catch regressions when [`agent_instructions.md`](demo/chat-bi/agent_instructions.md), [`RULES.md`](demo/chat-bi/RULES.md), [`nao_config.yaml`](demo/chat-bi/nao_config.yaml), [`semantic_models.yml`](models/semantic/semantic_models.yml), or [`marts.yml`](models/marts/marts.yml) change.

### Delivered in #86

- **SQL eval tests** in `demo/chat-bi/tests/*.yml` — `decommissioned_ports_check`, `lately_snapshot`, `network_reliability_uptime` added alongside existing [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml).
- **Analysis artifacts** — [`stage1_analysis.csv`](demo/chat-bi/tests/analysis/stage1_analysis.csv) and [`stage1_delta_summary.md`](demo/chat-bi/tests/analysis/stage1_delta_summary.md) filled for the expanded `nao test` run (2 passed, 2 failed — both failures: SQL binder error `Catalog "RAW" does not exist`, tracked as context/namespace drift signal).
- **Reproducible outputs** — Docker volume: host `demo/chat-bi/tests/outputs/` ↔ `/app/kwwhat/tests/outputs/`; `results_*.json` reachable without `docker cp` (see [`demo/README.md`](demo/README.md)).
- **Prompt wording** tightened to match SQL assertions.
- **Ignore rules** — local run noise excluded from commits.

### Approach locked for Stage 1 (carries forward as baseline convention)

- `nao test` + SQL = **factual** reference layer.
- Manual `semantic_label` / `failure_reason` = lightweight semantic layer; no automated G-eval judge in Stage 1.
- YAML cases called **"SQL tests"**; baseline shape = [`total_ports.yml`](demo/chat-bi/tests/total_ports.yml) structure.
- Storage: nao JSON pattern, Docker volume path above.
- **Upstream native evals** = parallel Stage 2 input, not a Stage 1 blocker.

### Decisions locked with #86

- `semantic_label` values: `correct` = accurate and complete; `partial` = correct conclusion but imprecise or incomplete; `incorrect` = factual error or hallucination.
- `status` and `semantic_label` are **independent layers** — harness pass/fail vs human rubric.
- Do not bulk-commit raw `results_*.json`; keep selected analysis artifacts only.

### Mini analysis table columns (Stage 1; extend for Stage 2)

`question`, `actual`, `expected` (optional), `status`, `semantic_label`, `failure_reason` (if fail), `cost`, `execution_time` (+ `run_id`, `model`, etc. already used in CSV).

---

## Test design constraints (all stages)

**Rules:** [`RULES.md`](demo/chat-bi/RULES.md), [`agent_instructions.md`](demo/chat-bi/agent_instructions.md), [`nao_config.yaml`](demo/chat-bi/nao_config.yaml) — DuckDB only, no schema introspection, only `fact_*`/`dim_*` tables (`analytics.ANALYTICS.<table>`), default time window last 7 days.

**SQL:** `sql:` must use real columns from [`marts.yml`](models/marts/marts.yml) and only metrics defined in [`semantic_models.yml`](models/semantic/semantic_models.yml).

**Time windows:** if expected SQL has no date filter and aggregates over all available data, the prompt must explicitly ask for "full history"; otherwise the default last-7-days rule applies.

**Reproducibility:** use `dbt run --full-refresh` for demo test setup when previous incremental state could affect eval outputs.

**Narrative:** `charge attempt`, `transaction`, `visit` — never `session`. Presentation rules (%, pp) apply to **answer quality** evaluation, not to the `sql:` block.

**No extra context in test prompts** — no injected chunks; tests exercise curated nao context only (`agent_instructions.md`, `RULES.md`, etc.).

---

## Scratch / course notes (ephemeral)

_Bullets from evals course / syncs. Trim or delete before merging to `main`._
