# Correctness Eval Plan (Plan B)

Reference-based correctness evals for nao chat answers, proposed for
[getnao/nao#727](https://github.com/getnao/nao/issues/727).

This is the **Plan B** specification. It is meant to be read side by side with the
**[Plan A](rag_triad_plan.MD)** proposal.

---

## 1. Background & Problem

nao's SQL tests check deterministic answers and query correctness. They cannot catch
**context drift**: the chat agent can return a numerically correct answer while
ignoring configured context (`rules.md`, semantic model/layer, framing, terminology).

As a nao user curating project context, I want to know when a change to my `rules.md`
or semantic model makes the agent hallucinate, use the wrong terminology, or ignore my
configuration — even when the SQL result is correct.

Plan B adds context-quality evals alongside SQL tests using a **reference-based**
check:

```text
input → nao agent → actual_output ↔ expected_output → DeepEval GEval → score / pass / reason
```

Exact numeric correctness stays in deterministic SQL tests. `nao evals` covers
semantic/context failures in the final answer. This is the same problem Plan A
targets; the two plans differ in *how* they measure it (see §2).

---

## 2. Approach: reference-based Correctness

Plan A is **referenceless** (RAG triad over captured context). Plan B is
**reference-based**: it compares the final answer directly with a golden
`expected_output` using DeepEval `GEval`.

The current metric is **Correctness**:

- Compare `actual_output` with `expected_output` for factual accuracy.
- Check that required facts, entities, values, and relationships are present.
- Check required terminology and framing.
- Penalize contradictions, unsupported additions, and misleading details.

**Assumption:** if the final answer matches the reference, the context the agent used
was probably good.

**What Plan B does not do:**

- It does not verify *which* context the agent actually used.
- It does not explain whether a failure came from missing context, hallucination, or
  another cause.
- It cannot distinguish **grounded additions** from **hallucinated additions**. A real
  run (`q001`, see §10 and [correctness_example_outputs.md](correctness_example_outputs.md)) demonstrated this: details that were
  present in project docs read by the agent were still penalized as "unsupported"
  because they were not in the reference.

**Cost:** every eval case needs a maintained `expected_output`.

---

## 3. Architecture — what exists today

`nao test` already runs the agent through the backend and returns the final answer:

- `POST /api/test/run` runs the agent non-streaming and returns
  `{ text, usage, cost, duration, tool_calls }`.
- The Python `AgentClient` (`cli/nao_core/commands/test/client.py`) already wraps this
  call, handles auth, and returns a typed `TestResult`.

Everything needed to obtain `actual_output`, token usage, cost, duration, and tool
counts already exists. Plan B reuses it.

---

## 4. What Changes in the Backend — nothing

**Plan B requires zero backend changes.**

Eval cases are sent through the existing `POST /api/test/run` with an empty `sql`
field, using the same `AgentClient` as `nao test`. There is:

- **no** new Fastify route (Plan A adds `POST /api/evals/chat`);
- **no** tool-result extraction or serialization;
- **no** content-bearing tool allowlist (`CONTEXT_TOOLS`) to maintain;
- **no** change to existing agent internals.

The only backend-adjacent change is an **optional** request timeout added to the
existing client (`timeout: float | None = None`), which is backward-compatible with
`nao test`.

This is the core reason Plan B is less invasive than Plan A.

---

## 5. Directory Layout

```text
# nao_core package (framework — shipped with nao)
cli/nao_core/commands/evals/
  case.py          # dataset discovery + JSONL validation
  correctness.py   # GEval Correctness metric + judge resolution
  runner.py        # execution, reporting, CLI entry point

# User's project (data — owned by the team)
{project}/tests/evals/
  golden_dataset.jsonl     # {id, input, expected_output}
{project}/tests/outputs/
  evals_results_<ts>.json  # generated reports
```

Eval cases live alongside existing `tests/*.yml` SQL tests.

---

## 6. Golden Dataset Schema

Each JSONL row has exactly three fields:

```json
{"id": "q001", "input": "Did we decommission the wrong port?", "expected_output": "Yes, we decommissioned CH001 that was the only functional charger."}
```

No SQL, context, or metric boilerplate.

Comparison with Plan A:

- Plan A requires `id`, `input` (context captured at runtime).
- Plan B requires `id`, `input`, **`expected_output`**.

---

## 7. Eval Harness Flow (per case)

```text
for each record in golden_dataset.jsonl:
  1. run agent via AgentClient.run_test(input, sql="", model, timeout)
       → actual_output (+ tokens, cost, duration, tool_calls)
  2. LLMTestCase(input, actual_output, expected_output)
  3. GEval(Correctness).measure(test_case)   → score, reason
  4. collect MetricResult(name, score, passed, reason, threshold)

after all records:
  5. save_results() → evals_results_<ts>.json with results + summary
  6. sys.exit(1) if any case failed
```

Error handling short-circuits the judge:

- **timeout** → case recorded `failed`, `error_type: "timeout"`, judge **not** run.
- **backend error** → `failed`, `error_type: "backend_error"`, judge **not** run.
- **unexpected error** during the agent run → `failed`, `error_type: "unexpected_error"`.
- **judge error** (agent answered, metric raised) → `failed`, `error_type: "metric_error"`.

---

## 8. Correctness Metric Configuration

The metric is a DeepEval `GEval` instance named `Correctness`.

**Evaluation steps** (aligned with the #727 rubric):

1. Compare the actual output directly with the expected output for factual accuracy.
2. Verify that every required fact, entity, value, and relationship in the expected
   output is present and correctly represented.
3. Verify that the actual output uses the required naming, terminology, and framing.
4. Penalize contradictions, unsupported additions, and misleading details, even when
   the core answer is present.

**Evaluation params:** limited to `ACTUAL_OUTPUT` and `EXPECTED_OUTPUT` only. `INPUT`
and any captured context are intentionally excluded — this is a reference-based check,
not a grounding check.

**Threshold:** `--threshold` defaults to `0.5`. This is a prototype default and must be
calibrated on repeated real runs before it is used as a blocking gate.

**Judge model (`--judge-model`):**

- Passed directly to `GEval`.
- Claude model strings (`claude-*` or `anthropic:claude-*`) are resolved through
  DeepEval's `AnthropicModel` adapter. Without this, DeepEval `4.0.7` treats a raw
  Claude string as an OpenAI model and the run fails.
- Other providers (OpenAI, etc.) are passed through as plain strings.
- Using the same model for agent and judge introduces self-serving bias; pass a
  different `--judge-model` for an independent judge.

Configured project LLM credentials are exported to DeepEval's expected env vars at
runtime (`configure_deepeval_env`) without overwriting an existing shell environment.

---

## 9. Runner Components

- **`case.py`**
  - `EvalCase` dataclass + `EvalCase.from_jsonl()` — parse and validate one row.
  - `discover_evals()` — load `tests/evals/golden_dataset.jsonl`, enforce required
    string fields (`id`, `input`, `expected_output`), reject duplicate ids, aggregate
    row-level errors.
- **`correctness.py`**
  - `CorrectnessEvaluator` — builds the `GEval` metric and `LLMTestCase`, returns a
    `MetricResult`.
  - `CORRECTNESS_STEPS` — the four evaluation steps above.
  - `_resolve_judge_model()` — Claude → `AnthropicModel`, else pass-through.
  - deepeval is imported lazily so the module loads without it installed.
- **`runner.py`**
  - `run_eval_case()` — single case: run agent, handle timeout/error, run metric.
  - `filter_eval_cases()` — `--select` id filter with de-duplication.
  - `save_results()` — write `evals_results_<ts>.json` with results + summary totals.
  - `evals()` — CLI entry point (`-m`, `-s`, `--dataset`, `--threshold`,
    `--judge-model`, `--timeout`, `-u`, `--password`, `-t`), non-zero exit on failure.

---

## 10. Running the Evals

```bash
# All cases
nao evals -m anthropic:claude-sonnet-4-6 --judge-model claude-sonnet-4-6 --timeout 120

# One case
nao evals -s q001 -m anthropic:claude-sonnet-4-6 --judge-model claude-sonnet-4-6 --timeout 30
```

Parameters:

- `-m`, `--model`: chat model being evaluated (`provider:model_id`).
- `--judge-model`: DeepEval GEval judge model.
- `--timeout`: max seconds for each agent request.
- `-s`, `--select`: eval id filter (e.g. `q001` or `q001,q002`).
- `--threshold`: minimum correctness score to pass (default `0.5`).

**Sample report** (excerpt from a real prototype run; full evidence in
[correctness_example_outputs.md](correctness_example_outputs.md)):

```json
{
  "results": [
    {
      "id": "q001",
      "input": "What business does this project represent?",
      "actual_output": "Jaffle Shop is a cafe and eatery specializing in jaffles...",
      "expected_output": "This project represents Jaffle Shop, a company that sells products to its customers.",
      "passed": false,
      "metrics": [
        { "name": "Correctness", "score": 0.3, "threshold": 0.5, "passed": false, "reason": "... adds extensive unsupported details not present in the expected output ..." }
      ],
      "tokens": 21759,
      "cost": 0.0322533,
      "duration_ms": 17576,
      "tool_call_count": 8
    }
  ],
  "summary": { "total": 2, "passed": 1, "failed": 1 }
}
```

Reporting notes:

- `duration_ms` is **agent-reported** duration, not end-to-end wall-clock and not judge
  time.
- Judge token usage and cost are **not** currently reported separately; the result
  model only carries agent usage.

Exit code: `0` when all cases pass; non-zero when any case fails, errors, or times out.

---

## 11. CI

Do not block every PR on LLM evals by default — they are slower and cost money. Use the
non-zero exit code for optional or scheduled runs instead.

---

## 12. Implementation Status & Sequence

1. **`cli/nao_core/commands/evals/{case,correctness,runner}.py`** — dataset discovery,
   Correctness metric, execution + reporting. — **Done, unit-tested.**
2. **Register command** in `cli/nao_core/commands/__init__.py` and
   `cli/nao_core/main.py`. — **Done.**
3. **Optional timeout** on the existing `AgentClient`. — **Done, backward-compatible.**
4. **`golden_dataset.jsonl`** in the target project. — **Done for `example` and
   kwwhat `demo/chat-bi`.**
5. **[correctness_example_outputs.md](correctness_example_outputs.md)** from real runs. — **Done (prototype runs).**

**Verified:**

- 24 focused unit tests (dataset validation, duplicate ids, rubric/params,
  score/pass/reason, timeout & backend errors skip the judge, non-zero exit).
- One real end-to-end run on the `example` project (agent + Claude judge, exit `1`).
- End-to-end run on the kwwhat demo (`q002`, availability-index case): score `0.7`,
  passed, exit `0`.
- `--judge-model claude-sonnet-4-6` resolved through `AnthropicModel`.

**Pending:**

- Timeout smoke test (confirm a hanging agent becomes a timeout result).
- **Dependency decision:** `deepeval` is currently a **core** dependency of
  `nao-core`. An optional `nao-core[evals]` extra would keep normal installs smaller
  and match the lazy imports, at the cost of extra install/docs/CI steps. Not yet
  decided.
- Regenerate `uv.lock` after the dependency decision.

---

## 13. Extending Later (→ Plan A / Plan C)

The golden dataset (`id`, `input`, `expected_output`) is forward-compatible with the
context metrics in Plan A. [Plan C](plan_c.md) (both) can add Correctness to the same
`metrics=[]` list that runs the RAG triad on a single `LLMTestCase`, reusing one agent
response.
Correctness explains *whether the answer matches the reference*; the triad explains
*why* an answer was or was not grounded.

---

## 14. Prototype Evidence

**[correctness_example_outputs.md](correctness_example_outputs.md):** the design PR should carry this real Plan B
prototype evidence (single run per case). A future side-by-side `example_outputs.md`
still requires real Plan A / Plan C runs on the same cases, model, and environment.
Report the median of three runs where practical; label a single run as a prototype,
not a production benchmark. The number of underlying judge-model calls is not
currently instrumented and must not be inferred from the number of metrics.

kwwhat `q002` (availability index; Plan A `q003`) scored `0.7` and passed. See the
[kwwhat run](correctness_example_outputs.md#kwwhat-demo-chat-bi--availability-index-case).


An operational runbook has been prepared separately and can be added after the design
direction is approved; it is not part of this decision.
