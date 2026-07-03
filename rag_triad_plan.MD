# Plan: LLM-as-Judge RAG Triad Evals for nao

## Background

nao's agent answers questions by reading file-based project context (schema docs, `columns.md`,
`preview.md`) and executing SQL. When a user asks a question, the agent:

1. Reads relevant files from the project folder (`read`, `grep`, `search`, `list` tools)
2. Executes SQL queries (`execute_sql` tool)
3. Composes a natural language response from those tool outputs

The **curated context** for evals is the subset of tool outputs that carry actual
content: `execute_sql`, `read`, `grep`.

This plan adds evals that measure context quality by borrowing the RAG triad framework — with one substitution: instead of retrieved context we will be assessing curated context. The assumption here is that if the context is good, the answer is likely correct without checking directly. The alternative reference-based approach in `correctness_plan.md` directly compares outputs against a maintained `expected_output` — fewer judge calls per record, but every entry requires a reviewed answer.

---

## Two Approaches to Curated Context

### Static: bake context into the golden dataset (rejected — not robust and hard to maintain)

Pre-record the tool outputs when building the dataset. Each golden record carries:

```jsonl
{
  "id": "q001",
  "input": "How many ports are currently decommissioned?",
  "expected_output": "...",
  "curated_context": [
    "[File: models/semantic/semantic_models.yml]\n# dim_ports\n- decommissioned_ts: timestamp when port was decommissioned, null if active",
    "[SQL result]\nColumns: decommissioned_ports\n4"
  ]
}
```

The eval test reads context directly from the file — no running backend needed.

**Downside:** Context goes stale the moment the project folder, schema docs, or SQL results change.
If nao's prompt is updated and the agent now reads different files or generates different SQL, the
golden context no longer reflects what the model actually used. You end up judging faithfulness
against a context that wasn't actually provided to the LLM — which defeats the metric entirely.
Every dataset update becomes a manual two-step: run the agent, copy the tool outputs, paste them
into the JSONL. This does not scale past a handful of records.

---

### Dynamic: capture context at eval runtime (chosen approach)

At eval time, call a dedicated nao endpoint that runs the agent and returns **both** the final
answer and the exact tool results that produced it, in a single response. The eval harness uses
those tool results directly as `retrieval_context` for DeepEval. No context is stored in the
dataset.

**Why this is correct:**

- The context passed to DeepEval is always the context that was actually provided to the LLM for
  *that specific run*. There is no staleness.
- If nao's prompt changes, the agent reads different files, or the database is updated, the eval
  automatically reflects the new reality — it measures faithfulness of what nao actually said
  against what nao actually saw.
- The golden dataset stays lean: only `input`. No manual context curation.
- It also enables a future regression signal: if faithfulness drops after a prompt or tool change,
  you know the model started making claims not grounded in its own context.

The only requirement is a running nao backend, which is already needed to get `actual_output`
anyway. The dynamic approach does require a dedicated eval endpoint (`POST /api/evals/chat`), tool output
filtering logic, and ongoing maintenance of the `CONTEXT_TOOLS` list — but these are contained
to one route file and one runner, rather than spreading context management into the dataset.

**Maintenance burden:** `CONTEXT_TOOLS` in `apps/backend/src/routes/evals.ts` must be kept in sync
as new agent tools are added. When a new tool is introduced, the nao team needs to decide whether
its output is content-bearing (add it) or navigation-only (leave it out). This is a small but
ongoing maintenance cost that the static approach does not have.

---

## Architecture

### What exists today

`AgentManager` in `apps/backend/src/services/agent.ts` has two execution modes:

- `stream()` — used by the main `/api/agent` route; returns a UI message stream to the browser
- `generate()` — non-streaming; returns `AgentRunResult` which already contains:
  ```typescript
  steps: ReadonlyArray<{
    toolCalls: ReadonlyArray<{ toolName: string; toolCallId: string; input: unknown }>;
    toolResults: ReadonlyArray<{ toolCallId: string; output?: unknown }>;
  }>
  ```

`steps[*].toolResults` is the exact grounding context. It is already collected internally — it just
has no HTTP endpoint that exposes it.

---

## What Changes in the Backend (minimal)

Add one new Fastify route: `POST /api/evals/chat`.

It mirrors `/api/agent` but:

1. Calls `testAgentService.runTest()` (same service used by `nao test`) — non-streaming, returns
   the full `AgentRunResult`
2. Returns JSON `{ text, model_id, tool_results }` instead of a UI message stream
3. `tool_results` = `TestAgentService.extractToolCalls(result)` filtered to content-bearing tools:
   `execute_sql`, `read`, `grep`
   — `list` and `search` are intentionally excluded: both return only file metadata
   (path/dir/size), not file content. They are navigation tools — the agent uses them to decide
   what to read next, not to compose its answer. Including them dilutes Contextual Relevancy
   with path listings that have no semantic relationship to the question.
4. Accepts an optional `model: { provider, modelId }` body field to override the project default

No changes to existing routes or agent internals. `generate()` is already exercised by automations.

**Response shape:**
```json
{
  "text": "Total sales by region last quarter were: North $1.2M...",
  "model_id": "claude-sonnet-4-6",
  "tool_results": [
    { "toolName": "read", "output": { "content": "# sales table\n..." } },
    { "toolName": "execute_sql", "output": { "columns": ["region", "total"], "data": [...] } }
  ]
}
```

`model_id` reflects whichever model ran — either the project default from Settings → Project →
Models, or the override passed in the request body.

---

## Directory Layout

Evals follow the same project-relative convention as `nao test`. The framework lives in the
`nao_core` package; the user's golden dataset lives in their project folder alongside other test
assets.

```
# nao_core package (framework — shipped with nao)
cli/nao_core/commands/evals/
  case.py                  # dataset discovery and JSONL validation
  runner.py                # full eval engine + CLI command

# User's project (data — owned by the team)
{project}/tests/evals/
  golden_dataset.jsonl     # {id, input} — no context, no expected output
```

`case.py` validates the dataset before any records are run — catching missing fields or duplicate
IDs upfront avoids wasting 3 paid LLM judge calls per bad record.

`runner.py` is both orchestration and eval engine — same pattern as `nao test`. It reads the
dataset, calls the backend, runs DeepEval metrics, writes the JSON report, and exits.

The `/api/evals/chat` call happens once per record regardless of how many metrics are active —
all metrics share the same `LLMTestCase` built from that single response.

---

## Golden Dataset Schema

```jsonl
{"id": "q001", "input": "How many ports are currently decommissioned?"}
{"id": "q002", "input": "What is the overall uptime percentage of my EV charging network for the full history?"}
{"id": "q003", "input": "What is the charge point availability index?"}
```

No `curated_context` or `expected_output` field. Context is captured live. `expected_output` is only needed if Completeness (`GEval`) is added later — add it back to the dataset at that point.

---

## Eval Harness Flow (per test case)

```
for each record in golden_dataset.jsonl:
  1. POST /api/evals/chat  { input: record.input, model?: { provider, modelId } }
  2. → { text: <actual_output>, model_id: <model>, tool_results: [...] }
  3. curated_context = [serialize(tr) for tr in tool_results]
  4. LLMTestCase(
       input             = record.input,
       actual_output     = response.text,
       retrieval_context = curated_context,
     )
  5. for each metric: metric.measure(test_case)   # populates .score and .reason on the same instance
     collect MetricResult(name, score, threshold, passed, reason)

after all records:
  6. save_results() → evals_{timestamp}.json with results + summary
  7. sys.exit(1) if any record failed
```

All three metrics measure the same `LLMTestCase`. DeepEval reports each score and reason
independently — a failure in one does not suppress the others.

**Tool result serialization**:

| Tool | Returns | Included | Reason |
|---|---|---|---|
| `execute_sql` | data rows | yes | primary grounding — the actual query results the agent used |
| `read` | full file content | yes | schema docs, column descriptions, semantic models |
| `grep` | matching lines + context | yes | actual file content snippets |
| `search` | path/dir/size | **no** | glob file finder — navigation only, no content |
| `list` | path/dir/size | **no** | directory listing — navigation only, no content |

`search` and `list` are excluded for the same reason: both return only file metadata. They are
navigation tools the agent uses to decide what to read next — not to compose its answer. Including
them adds path listings with no semantic relationship to the question, diluting Contextual
Relevancy without adding grounding signal.

---

## DeepEval Metric Configuration

```python
FaithfulnessMetric(threshold=0.7, model=judge, include_reason=True)
ContextualRelevancyMetric(threshold=0.5, model=judge, include_reason=True)
AnswerRelevancyMetric(threshold=0.7, model=judge, include_reason=True)
```

**Contextual Relevancy threshold is intentionally lower than the other two metrics.** In a classic
RAG pipeline, retrieval is scoped tightly to the question — only the most relevant chunks are
fetched. A chat agent works differently: it reads schema docs, semantic model definitions, and
column descriptions to build a broad understanding of the data model before it can compose a
correct answer. Much of that context is genuinely necessary for the agent to reason well, but it is
not directly about the specific question. The result is that Contextual Relevancy is structurally
diluted compared to a purpose-built retrieval system — by design, not by failure.

It addition to that, the right Contextual Relevancy threshold depends on the project's data scope. A single-domain
project (only EV charger data) will have tighter, more focused context than a multi-domain one
(sales + HR + finance) — so 0.5 might be too strict for a broad deployment and too loose for a
narrow one.

This means a score of 0.5–0.65 on Contextual Relevancy may reflect a well-functioning agent
rather than a broken retrieval step and should be calibrated per project.

**Per-project threshold configuration**

 Thresholds should be tunable per project via `nao.yml`:

```yaml
evals:
  thresholds:
    faithfulness: 0.7
    contextual_relevancy: 0.3
    answer_relevancy: 0.7
```

`runner.py` reads `nao.yml` via the existing `NaoConfig` loader (same as `nao test`), falling back
to the hardcoded defaults if the section is absent. Not yet implemented — add when the first
project needs a different threshold.

**Self-serving bias and `--judge-model`**

Using the same model as judge introduces self-serving bias — a model tends to score its own outputs
higher. To use an independent judge, pass `--judge-model` with a different model. The agent runs
with its configured model; the judge runs with the override:

```bash
nao evals -j openai:gpt-4.1
nao evals -m anthropic:claude-sonnet-4-6 -j openai:gpt-4.1
```

Without `--judge-model`, the judge defaults to whatever model the agent used (`model_id` from the
response). `-m` alone does not give you an independent judge — it changes the agent model, and the
judge follows it.

---

## `runner.py` Functions

- **`serialize_tool_result(tool_name, args, output)`** — converts a raw tool call result into a
  plain string for `retrieval_context`. Formats `read` as `[File: path]\ncontent`, `execute_sql`
  as a column/row table, everything else as JSON.
- **`make_judge(model_id)`** — returns a `_ClaudeJudge` (`DeepEvalBaseLLM` subclass) for Claude
  models, or a plain string for OpenAI (DeepEval handles those natively). deepeval is imported
  lazily inside this function so the module loads without it installed.
- **`run_eval(record, client, model, judge_model, verbose)`** — single eval loop for one record:
  POST to `/api/evals/chat`, build `LLMTestCase`, instantiate metrics with `judge_model` (or agent
  model if not set), call `metric.measure()` on each, collect `MetricResult` dataclasses, return
  `EvalResult`.
- **`save_results(results, output_dir)`** — writes `evals_{timestamp}.json` with `results` list
  and `summary: { total, passed, failed }`.
- **`evals(...)`** — CLI entry point; reads dataset, authenticates, iterates records via
  `run_eval()`, saves results, prints summary, calls `sys.exit(1)` if any failed.

---

## Running the Evals

```bash
# Start nao backend normally
npm run dev -w @nao/backend

# Run all evals (from your project directory)
nao evals

# Specify the agent model (mirrors nao test -m)
nao evals -m anthropic:claude-sonnet-4-6

# Use an independent judge model
nao evals -j openai:gpt-4.1

# Agent and judge on different models
nao evals -m anthropic:claude-sonnet-4-6 -j openai:gpt-4.1

# Verbose output (prints metric reasons)
nao evals -v

# Run a single record by ID
nao evals -s q001

# Explicit credentials
nao evals -u user@example.com --password secret
```

Install eval deps once with `uv sync --extra evals` from `cli/`. The `evals` extra adds only
`deepeval` — provider SDKs come from the user's existing nao installation.

Add `make evals` to the root `Makefile` for consistency with `make lint`.

**Example output (`-v`):**

```
Running: q001 How many ports are currently decommissioned?
  ✓ Faithfulness: 1.0
    The score is 1.00 because the actual output is perfectly faithful to the retrieval context with no contradictions found!
  ✓ ContextualRelevancy: 0.8333
    The score is 0.83 because most of the retrieval context is highly relevant, directly addressing the question with key
    details such as the SQL query filtering 'decommissioned_ts IS NOT NULL', the result alias 'decommissioned_ports', and
    the concrete answer of '4 decommissioned ports'. However, one statement about 'COUNT(DISTINCT port_id)' counting total
    ports without any decommissioned filtering is irrelevant and slightly reduces the overall score.
  ✓ AnswerRelevancy: 1.0
    The score is 1.00 because the response directly and completely addresses the question about the number of currently
    decommissioned ports, with no irrelevant statements whatsoever. Great job!
```

Without `-v`, only the score line is printed. Results are always written to
`{project}/tests/outputs/evals_{timestamp}.json`:

```json
{
  "timestamp": "2026-06-25T21:35:40.653031",
  "results": [
    {
      "id": "q001",
      "input": "How many ports are currently decommissioned?",
      "actual_output": "There are currently <citation-number id=\"query_47c75c22\" column=\"decommissioned_ports\">4</citation-number> decommissioned ports (those with a non-null `decommissioned_ts`).",
      "passed": true,
      "metrics": [
        { "name": "Faithfulness",         "score": 1.0,    "threshold": 0.7, "passed": true, "reason": "The score is 1.00 because the actual output is perfectly faithful to the retrieval context with no contradictions found!" },
        { "name": "ContextualRelevancy",  "score": 0.8333, "threshold": 0.5, "passed": true, "reason": "The score is 0.83 because most of the retrieval context is highly relevant, directly addressing the question with key details such as the SQL query filtering 'decommissioned_ts IS NOT NULL', the result alias 'decommissioned_ports', and the concrete answer of '4 decommissioned ports'. However, one statement about 'COUNT(DISTINCT port_id)' counting total ports without any decommissioned filtering is irrelevant and slightly reduces the overall score." },
        { "name": "AnswerRelevancy",      "score": 1.0,    "threshold": 0.7, "passed": true, "reason": "The score is 1.00 because the response directly and completely addresses the question about the number of currently decommissioned ports, with no irrelevant statements whatsoever. Great job!" }
      ]
    },
    {
      "id": "q002",
      "input": "What is the overall uptime percentage of my EV charging network for the full history?",
      "actual_output": "Overall Uptime: 99.71% across Sep 15, 2025 – Jun 26, 2026. All 4,986 downtime minutes were concentrated in October 2025. Every other month recorded 100% uptime.",
      "passed": true,
      "metrics": [
        { "name": "Faithfulness",          "score": 0.8889, "threshold": 0.7, "passed": true,  "reason": "The score is 0.89 because the actual output incorrectly states total commissioned minutes as 1,722,240 when the retrieval context specifies 1,716,480." },
        { "name": "ContextualRelevancy",  "score": 0.507,  "threshold": 0.5, "passed": true,  "reason": "The score is 0.51 because while a significant portion of the retrieval context is irrelevant (empty SQL results, database metadata, schema config), the context contains the direct answer '99.71% uptime' and supporting breakdowns. The large volume of irrelevant context dilutes the score." },
        { "name": "AnswerRelevancy",      "score": 0.8182, "threshold": 0.7, "passed": true,  "reason": "The score is 0.82 because the output addresses overall uptime but includes unnecessary detail about which chargers caused the downtime events — not directly relevant to the question asked." }
      ]
    }
    {
      "id": "q003",
      "input": "What is the charge point availability index?",
      "actual_output": "Charge Point Availability Index is not a defined metric in the semantic model. The closest metric is uptime — it measures the fraction of commissioned time that a port was operational. Would you like me to report on uptime, or define a new metric?",
      "passed": false,
      "metrics": [
        { "name": "Faithfulness",        "score": 1.0,    "threshold": 0.7, "passed": true,  "reason": "The score is 1.00 because the actual output is perfectly faithful to the retrieval context with no contradictions found!" },
        { "name": "ContextualRelevancy", "score": 0.0,    "threshold": 0.5, "passed": false, "reason": "The score is 0.00 because the retrieval context contains no relevant statements about a 'charge point availability index'. The context only covers unrelated semantic models such as 'visits' and 'charge_attempts'." },
        { "name": "AnswerRelevancy",     "score": 0.5714, "threshold": 0.7, "passed": false, "reason": "The score is 0.57 because while the response attempts to address the charge point availability index, it includes several irrelevant metrics (total_visits, total_charge_attempts, etc.) that dilute the focus." }
      ]
    }
  ],
  "summary": {
    "total": 3,
    "passed": 1,
    "failed": 2
  }
}
```

Both records pass. ContextualRelevancy in both cases is flagged as diluted.

---

## CI

Do not block PRs on evals — they are slow (~5–10 s per LLM judge call) and cost money.

---

## Implementation Sequence

1. **Add `POST /api/evals/chat` Fastify route** — ~40 lines in `apps/backend/src/routes/evals.ts`;
   calls existing `testAgentService.runTest()`, returns `{ text, model_id, tool_results }`, accepts
   optional `model` override
2. **Register route** in `apps/backend/src/app.ts` under `/api/evals`
3. **Write `cli/nao_core/commands/evals/runner.py`** — full eval engine mirroring `nao test`;
   `EvalResult` / `MetricResult` dataclasses; `serialize_tool_result`, `make_judge`, `run_eval`,
   `save_results` functions; `evals()` CLI entry point with `-m`, `-u`, `--password`, `-v`, `-s`
   flags; deepeval imported lazily so the module loads without it installed; `sys.exit(1)` if any
   record fails
4. **Register command** in `cli/nao_core/commands/__init__.py` and `cli/nao_core/main.py`
5. **Add `evals` extra** to `cli/pyproject.toml` — `deepeval>=2.0` only
6. **Populate `{project}/tests/evals/golden_dataset.jsonl`** — Q&A pairs from golden dataset

---

## Adding Completeness Later

The full triad ships from day one. Completeness is the only metric deferred — it has no
first-class DeepEval class yet. When ready, adding it is one step:

1. Add a `GEval` instance to the `metrics=[]` list in `run_eval()` with a rubric such as
   "does the answer fully address all parts of the question, given the expected output?"

Requires adding `expected_output` back to the golden dataset records and passing it to `LLMTestCase`. No other changes.

| Metric | DeepEval class | Ships | Fields used |
|---|---|---|---|
| Faithfulness | `FaithfulnessMetric` | Day 1 | `input`, `actual_output`, `retrieval_context` |
| Context relevance | `ContextualRelevancyMetric` | Day 1 | `input`, `retrieval_context` |
| Answer relevance | `AnswerRelevancyMetric` | Day 1 | `input`, `actual_output` |
| Completeness | `GEval` (custom rubric) | Later | `input`, `actual_output`, `expected_output` |
