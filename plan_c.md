# Combined Eval Plan (Plan C)

Plan C is the **union of Plan A (RAG triad) and Plan B (Correctness)** for
[getnao/nao#727](https://github.com/getnao/nao/issues/727). It is not a new
architecture — it composes the two existing proposals. Read
[rag_triad_plan.MD](rag_triad_plan.MD) and
[correctness_plan.md](correctness_plan.md) first; this document only describes how
they combine.

The point of C is to avoid relying on either single assumption:

- Plan A assumes that relevant, grounded, on-topic context implies a likely-correct
  answer, but does not check correctness directly.
- Plan B assumes that a reference match implies good context, but does not verify which
  context the agent used or explain *why* a case failed.

Plan C runs both, so the RAG triad explains **why** an answer was or was not grounded
while Correctness verifies the **final answer against the reference**.

---

## 1. What Plan C adds over A and B

Nothing structurally new. Plan C:

- reuses Plan A's `POST /api/evals/chat` route and content-bearing tool capture;
- reuses Plan B's `Correctness` `GEval` rubric;
- runs **all four metrics on a single `LLMTestCase`** built from **one** agent
  response.

There is no separate Plan C runner — it is the same runner with both metric sets in one
`metrics=[]` list.

---

## 2. Single agent run, four judge metrics

For each record:

```text
1. POST /api/evals/chat { input }  → { text, model_id, tool_results }   # one agent run
2. LLMTestCase(
     input             = record.input,
     actual_output     = text,
     expected_output   = record.expected_output,   # for Correctness
     retrieval_context = [serialize(tr) for tr in tool_results],  # for the triad
   )
3. metrics = [
     FaithfulnessMetric,
     ContextualRelevancyMetric,
     AnswerRelevancyMetric,
     GEval(Correctness),
   ]
4. for each metric: metric.measure(test_case)   # 4 metric evaluations
```

The agent runs **once**; the four metrics share its response. This is why Plan C cost
must **not** be estimated as "Plan A + Plan B" — the agent run is not duplicated.

Plan C keeps the same ownership split: DeepEval owns the triad prompts, while nao
defines the Correctness evaluation steps and rubric.

---

## 3. Dataset

Union of both requirements, which is exactly Plan B's schema:

```json
{"id": "q001", "input": "...", "expected_output": "..."}
```

- `id`, `input` — used by the triad (context captured at runtime).
- `expected_output` — used by Correctness.

No context is stored in the dataset; it is captured live via `/api/evals/chat`.

---

## 4. Footprint

Plan C inherits **Plan A's invasiveness**:

- new backend route `POST /api/evals/chat`;
- tool-result extraction + serialization;
- `CONTEXT_TOOLS` allowlist to maintain;

plus **Plan B's** maintained `expected_output` per case.

It is the strongest coverage and the highest combined implementation + maintenance
cost of the three options.

---

## 5. Cost

Per case: **one agent run + four judge metrics** (3 triad + 1 Correctness). The
underlying judge-model call count is not currently instrumented; a DeepEval metric may
make more than one model call internally.

- Do not add Plan A and Plan B costs naively — both reuse the same agent response.
- Report agent tokens/cost from the response; judge tokens/cost are only included when
  the runner exposes them (currently not separated for the DeepEval judge).

---

## 6. When to choose Plan C

- You want both a *why-it-failed* diagnosis (triad) and a *matches-the-reference*
  guarantee (Correctness) on the same case.
- You accept the backend + context-capture footprint of Plan A and the
  `expected_output` maintenance of Plan B.

If either the footprint or the maintenance cost is not acceptable yet, ship A or B
first and extend it later:

- Starting from Plan A requires adding `expected_output` to the dataset and appending
  Correctness to the triad's `metrics=[]` list.
- Starting from Plan B keeps its dataset but requires Plan A's `/api/evals/chat`
  endpoint, runtime context capture, tool filtering, and three triad metrics.

---

## 7. Implementation Status

Plan C is currently a **design-only composition**. Plans A and B have separate
prototype evidence, but Plan C has not yet been implemented or verified with a
controlled run where both metric sets evaluate the same saved agent response.

---

## 8. Comparison and Evidence

The shared A/B/C comparison table belongs in the design comment on
[getnao/nao#727](https://github.com/getnao/nao/issues/727), not in the individual
plans. A fair comparison in `example_outputs.md` requires real runs of all three
options on the same cases, model, and environment (median of three where practical);
label single runs as prototypes, not production benchmarks.
