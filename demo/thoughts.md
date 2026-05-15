# Thoughts — golden dataset format

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

| Category | Criteria |
|----------|----------|
| `metric_validity` | Did the model avoid inventing metrics not defined in the context? |
| `faithfulness` | Does the answer stick to facts — no hallucination or unsupported claims? |
| `answer_relevance` | Does the answer address the user input? |
| `terminology` | Did the model use correct vocabulary ("charge attempt" / "visit", never "session")? |
| `completeness` | Does the response cover everything the user input asked for? |

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
