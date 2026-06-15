# Thoughts — golden dataset format

## What we're building

**Goal** — implement an evals framework that quantifies the impact of context changes on the nao Chat BI tool. We are not testing the LLM or general chat performance. We are testing one specific thing: did a change to the context — RULES.md, semantic model definitions, or similar input files — make the assistant's answers better or worse? The eval score is a signal for context quality, not model quality. Nao already has SQL tests in place that guard against schema linking failures and semantic gaps. We are looking to add non-deterministic evals that catch failures when the SQL and even the number is correct.


## Design choices

We are adding **LLM-as-a-judge, single-turn, reference-based evals** to this project. Here is what each term means:

**LLM-as-a-judge** — instead of checking outputs with deterministic rules or exact string matches, a second LLM (the "judge") reads the assistant's response and scores it against expected answer. This handles the inherent non-determinism of Chat BI.

**Single-turn** — each eval entry is a single, atomic unit of interaction with the LLM app: one user input, one assistant response, no conversation history. The assistant is evaluated on what it says in that one reply, in isolation.

**Reference-based** — every entry includes a `reference_answer` that describes what a correct response looks like. The judge uses this as the gold standard — not to demand an exact match, but to assess whether the actual response aligns with the same intent, facts, and format. This grounds the judge's scoring in whether the agent arrived at the expected answer rather than asking it to reason from the rubric alone.

**End-to-end** — we evaluate the observable input and output of the Chat BI system and treat it as a black box. We do not instrument internal steps — no retrieval spans, no tool call traces, no sub-agent scoring. We care about the result the user sees, not the path the system took to produce it. This is the right fit for context-change evals: if the answer improved, the context change worked, regardless of what happened inside.

**Local-first** — the eval harness runs entirely on the developer's machine, with no external eval platform or cloud service required. The golden dataset, judge prompts, scores, and results all live in this repository. This keeps the feedback loop fast, keeps data private, and means the eval is as easy to run as any other dbt command.

**Same model as judge** — we plan to use the same model that powers Chat BI as the judge. This simplifies setup: no second API key, no model version management, no configuration drift. The trade-off is that models tend to score their own outputs more favorably — a known bias in self-evaluation. We accept this for now in exchange for simplicity, and can swap in a separate judge model later if scores prove unreliable.

**Eval framework (deepeval or similar)** — rather than hand-rolling judge prompts, we intend to use an established eval framework. This means the noa labs team does not need to become prompt engineering experts just to run evaluations — the framework owns the judge prompt design and scoring logic. It also provides a foundation that can be extended to multi-turn evals later without rebuilding from scratch.

---

## Framework options

| | DeepEval | Latitude | In-house |
|--|----------|----------|----------|
| **Approach** | Pre-built generic metric library | Evals derived from production failures and expert judgment | Hand-rolled judge prompts |
| **Best for** | Pre-production unit testing — useful when there is no production traffic yet | Post-production — requires real failure data to work from | Full control, no dependencies |
| **Main value** | No prompt engineering required; plug in metrics and run | Evals grounded in actual user failures, not generic rubrics | Fully tailored to the use case |
| **Main risk** | Score quality depends on golden dataset quality — the framework is only as good as the reference answers | Not useful pre-production; concedes this itself | Requires prompt engineering expertise; hard to maintain |
| **Multi-turn path** | Built in | Built in | Rebuild from scratch |

**Why this matters for nao:** we are targeting reference-based evals and assume end users arrive with a golden dataset. This changes the comparison significantly. The "generic metrics lie" concern — the main argument against DeepEval — is largely neutralised when every entry has a `reference_answer`: the judge is not scoring in the abstract, it is comparing against a concrete expected output. Latitude's value proposition (evals grounded in real production failures) does not apply here; a golden dataset replaces the need for production traffic. In-house also becomes more viable since comparing against a reference answer is a simpler judge prompt than scoring on abstract rubrics — but DeepEval still wins on setup cost and the multi-turn path for the noa labs team.

---

# Metrics borrow from RAG triad

RAG retrives context, which is different from what nao's users are doing - they curate context. We can account for this difference and reuse RAG metrics. 

RAG traid tests relationship b/w three entities: Question, Context and Response with metrics around 1. `Context Relevance` - is the context retried relevant to the question; 2. answer `Faithfulness` - was the answer grounded in retrived context; 3. `Answer Relevance` - is the answer relevant to what was asked. We can re-use this methodology by substituting retrived context with curated context. So the question changes from `Was the right context retrived` to `Was the right context curated`? 

| Metric | Inputs | What it checks |
|--------|--------|-------|
| Context Relevance | input and curated_context | Was the context relevant to the question? |
| Faithfulness | input, actual_output, and curated_context | Is every claim grounded in the curated context — no hallucinations? |
| Answer relevance | input and actual_output | Does the response address what the user actually asked? |
| Completeness | input and actual_output | Did the response cover the full scope of the question at the right level of detail? |

So the challenge will be to attache curated context to the test at runtime. Other than that, the triad itself seems very close to what nao users might want to accomplish with their evals.




## Do not use the rest
---

## Proposed entry format

```yaml
- question_id: q009
  category: metric_validity
  eval_type: LLM-as-judge
  user_input: "What is the charge point availability index?"
  primary_context: models/semantic/semantic_models.yml
  reference_answer: |
    The metric "charge point availability index" is not defined in the semantic model.
    The closest available metric is **uptime**. Would you like that instead?
  reference_contexts:
    - file: models/semantic/semantic_models.yml
      hint: only metrics defined here are valid
    - file: demo/chat-bi/RULES.md
      hint: do not make up metrics
  human_explanation: Model must decline and redirect — no hallucinated metrics.
```

## Field notes

| Field | Purpose |
|-------|---------|
| `category` | groups entries by rubric (`metric_validity`, `terminology`, `rate_format`, `completeness`) |
| `eval_type` | `LLM-as-judge` or `sql` — determines how the harness evaluates the answer |
| `primary_context` | single file path for reviewer traceability — not injected into prompts |
| `reference_contexts` | supporting evidence pointers for reviewer traceability; not injected into prompts |
| `reference_answer` | what a correct answer looks like — format and intent, not exact match |
| `human_explanation` | one line; captures the rubric intent for the judge prompt |

## Categories to consider

| Category | Criteria | Why it matters | Approach |
|----------|----------|----------------|----------|
| `sql_test` | Exact match against SQL assertion | catches regressions in factual outputs immediately | rule |
| `metric_validity` | Did the model avoid inventing metrics not defined in the context? | prevents made-up KPIs from reaching dashboards and decisions | LLM-as-judge |
| `faithfulness` | Does the answer stick to facts — no hallucination or unsupported claims? | prevents hallucinations, ensures traceable answers, builds user trust | LLM-as-judge |
| `answer_relevance` | Does the answer address the user input? | ensures the response is useful, not just grounded in context | LLM-as-judge |
| `terminology` | Did the model use correct vocabulary ("charge attempt" / "visit", never "session")? | keeps domain language consistent across the product and reports | LLM-as-judge |
| `completeness` | Does the response cover everything the user input asked for? Is it complete? Is it at the right level of detail? | avoids partial answers that require follow-up or cause misinterpretation | LLM-as-judge |

## Open question

Should `primary_context` point to the file that lets a reviewer **verify** the answer
(e.g. `semantic_models.yml` to confirm the metric doesn't exist), or the file that
states the **rule** being tested (e.g. `RULES.md` — "do not make up metrics")?

---

## Eval prompt

Two parts: a **system prompt** (static, judge persona) and a **user prompt** (rendered per entry).

### System prompt

```
You are an evaluator for a BI chat assistant that answers questions about EV charging networks.
Your job is to score the assistant's response against the reference answer and criteria provided.
Be strict and concise. Return only valid JSON.
```

### User prompt template

```
## User input
{{ user_input }}

## Reference answer
{{ reference_answer }}

## Evaluation criteria
Category: {{ category }}
Criteria: {{ criteria }}
{{ human_explanation }}

## Actual response
{{ actual_response }}

**ANALYZE THE ACTUAL RESPONSE FOR THIS USER INPUT**

Assess:

1. **usefulness** ("high" / "medium" / "low"): How closely does the actual response align with the reference answer?
   - "high": Matches the reference answer in intent, format, and key facts
   - "medium": Partially aligned — correct intent but missing format or key details
   - "low": Misaligned — wrong intent, wrong facts, or contradicts the reference answer

2. **signal_pct** (0–100): What percentage of this actual response is RELEVANT to the reference answer?
   - 80–100: Highly focused, almost all content maps to the reference answer
   - 50–79: Majority relevant, some content not in the reference answer
   - 20–49: Less than half maps to the reference answer
   - 0–19: Almost no overlap with the reference answer

3. **note**: Brief explanation (1 sentence)

**KEY TRADEOFFS TO CONSIDER:**
- A short reply can have HIGHER signal than a long one — brevity is not a flaw if the answer is complete

**BE STRICT:**
- Do not give "high" if the response is missing key facts or format requirements from the reference answer
- Do not round up signal_pct — penalize filler, hedging, or content not grounded in the reference answer
- A polite but wrong answer is still "low"

**OUTPUT FORMAT (JSON):**
{
  "question_id": "{{ question_id }}",
  "category": "{{ category }}",
  "summary": {
    "usefulness": "high" | "medium" | "low",
    "signal_pct": 0-100,
    "note": "<one sentence>"
  }
}
```

### Notes

- `primary_context` is a reviewer traceability pointer — not injected into the judge prompt.
- The judge model goes into a `judge_model` field on the result record (not in the prompt itself).

## Execution strategy

**Prompt chaining** — break eval into stages where each stage feeds the next:

1. **Retrieve** — fetch the actual response for a `question_id` from the chat log
2. **Judge** — render the user prompt template and call the judge model; get back the JSON score
3. **Aggregate** — collect scores across entries, compute pass rates per category

Each stage is a discrete LLM call (or SQL step). The output of one becomes the input of the next. This keeps each prompt focused and makes failures easy to isolate.
