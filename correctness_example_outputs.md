# Correctness Eval Prototype Output

This is evidence from prototype runs with one run per case, not a production
benchmark. LLM answers, scores, latency, and cost may vary between runs.

## Environment

- Date: 2026-07-01
- Runtime: Docker Desktop (Linux container)
- Image: `getnao/nao:correctness-local`
- Project: nao built-in `example` project (Jaffle Shop)
- nao-core: `0.1.9`
- DeepEval: `4.0.7`
- Agent model: `anthropic:claude-sonnet-4-6`
- Judge model: `claude-sonnet-4-6` through DeepEval `AnthropicModel`
- Correctness threshold: `0.5`
- Runs per case: `1`

Command:

```bash
nao evals \
  -m anthropic:claude-sonnet-4-6 \
  --judge-model claude-sonnet-4-6 \
  --timeout 120
```

The command completed both cases and exited `1` because one case failed.

## Results

### q001

Input:

```text
What business does this project represent?
```

Expected output:

```text
This project represents Jaffle Shop, a company that sells products to its customers.
```

Actual output:

```text
**Jaffle Shop** is a cafe and eatery specializing in **jaffles** — toasted sandwiches with a variety of savory and sweet fillings. Here's a quick summary:

**What they sell:**
- Signature jaffles (e.g., ham & cheese, pulled pork with apple slaw, brie with cranberry)
- Vegetarian & vegan jaffle options
- Specialty coffee, fresh juices, and smoothies

**Key values:**
- Locally-sourced, high-quality ingredients
- A cozy, welcoming atmosphere for casual dining and brunch

The database (`jaffle_shop`) tracks the business's operations — customers, orders, products, and sales data — which we can use to analyze performance and answer business questions.
```

Metric result:

- Score: `0.3`
- Passed: `false`
- Reason: The actual output contains the core concept that Jaffle Shop is a business that sells products to customers, which aligns with the expected output. However, the actual output adds extensive unsupported details not present in the expected output, such as specific menu items (ham & cheese, pulled pork with apple slaw, brie with cranberry), business values, atmosphere descriptions, and database specifics. The expected output is minimal and generic, simply stating Jaffle Shop is 'a company that sells products to its customers.' The actual output over-elaborates with speculative details and does not use the simple, neutral framing required. These unsupported additions and divergence from the expected terminology and framing are significant shortcomings.
- Agent-reported duration: `17.576s`
- Agent tokens: `21,759`
- Agent cost: `$0.0322533`
- Tool calls: `8`

### q002

Input:

```text
What should you do if I do not provide enough details for an analysis?
```

Expected output:

```text
Ask me for more details before proceeding with the analysis.
```

Actual output:

```text
As stated in my instructions: if you don't provide enough details, I'll **ask for more details** before proceeding.

I won't make assumptions or run analyses based on incomplete information — I'll ask you to clarify what you need so I can give you accurate and relevant results.
```

Metric result:

- Score: `0.6`
- Passed: `true`
- Reason: The actual output conveys the same core behavior as the expected output — asking for more details before proceeding. However, the actual output includes additional unsupported elaboration ('I won't make assumptions or run analyses based on incomplete information') that goes beyond the expected output. The framing is also inverted: rather than directly asking for more details (as the expected output instructs), the actual output describes its own behavior in third-person/meta terms. This is a functional match but with deviation in framing, tone, and added content not present in the expected output.
- Agent-reported duration: `3.292s`
- Agent tokens: `3,889`
- Agent cost: `$0.00325665`
- Tool calls: `0`

## Summary

- Total: `2`
- Passed: `1`
- Failed: `1`
- Agent tokens: `25,648`
- Agent cost: `$0.03550995`
- Sum of agent-reported durations: `20.868s`
- Judge tokens: not reported separately
- Judge cost: not reported separately
- End-to-end wall-clock duration: not captured separately

## Known Limitations

- This is one run per case, so it does not establish score stability or production cost.
- The report contains agent usage only. DeepEval's Anthropic judge usage and cost are
  not exposed by the current result model.
- Correctness sees only `actual_output` and `expected_output`. It does not receive
  project or tool context.
- In q001, several details penalized as unsupported by the reference were present in
  project documentation read by the agent. This demonstrates the intended tradeoff:
  Plan B checks reference match but cannot distinguish grounded additions from
  hallucinated additions.
- The `0.5` threshold is a prototype default and needs calibration across repeated
  project runs before it becomes a blocking gate.

---

## kwwhat demo (Chat BI) — availability index case

This section is a separate prototype run on the kwwhat EV charging demo project.
It uses the semantic model and `RULES.md` from `demo/chat-bi`.

**Plan mapping:** this case is `q002` in the kwwhat correctness dataset and
corresponds to **`q003` in the RAG triad plan** (`rag_triad_plan.MD`).

### Environment

- Date: 2026-07-01
- Runtime: Docker Desktop (Linux container)
- nao image: `getnao/nao:local` (built from `scratch/nao-correctness-evals`)
- chat-bi image: `demo-chat-bi` (rebuilt after dataset copy)
- Project: `kwwhat-demo` (`/app/kwwhat` in container)
- Dataset: `demo/chat-bi/tests/evals/golden_dataset.jsonl`
- nao-core: `0.1.9`
- DeepEval: `4.0.7`
- Agent model: `anthropic:claude-sonnet-4-6`
- Judge model: `claude-sonnet-4-6` through DeepEval `AnthropicModel`
- Correctness threshold: `0.5`
- Runs per case: `1`

Command:

```bash
nao evals -s q002 \
  -m anthropic:claude-sonnet-4-6 \
  --judge-model claude-sonnet-4-6 \
  --timeout 120
```

Exit code: `0` (case passed).

Report: `demo/chat-bi/tests/outputs/evals_results_20260701_194726.json`

### q002 — charge point availability index

Input:

```text
What is the charge point availability index?
```

Expected output:

```text
The metric "charge point availability index" is not defined in the semantic model. The closest available metric is **uptime**. Would you like that instead?
```

Actual output:

```text
The semantic model does not define a **"charge point availability index"** metric. The defined metrics are:

| Metric | Description |
|---|---|
| `total_visits` | Total number of charging visits |
| `total_charge_attempts` | Total charge attempts across all visits |
| `average_attempts_per_visit` | Avg attempts per visit |
| `first_attempt_success_rate` | % of visits where first attempt succeeded |
| `troubled_success_rate` | % of visits that succeeded with multiple attempts |
| `failed_rate` | % of visits that failed |
| `uptime` | Average port uptime (fraction of commissioned time not lost to outages) |

The closest defined metric to "availability" is **`uptime`** — the average fraction of commissioned time that a port was operational and not in outage. There is no metric called "charge point availability index" in the semantic model.

Would you like me to report on **uptime** as the availability proxy, or is there a specific calculation you have in mind for an availability index?
```

Metric result:

- Score: `0.7`
- Passed: `true`
- Reason: The actual output correctly identifies that 'charge point availability index' is not defined in the semantic model and correctly points to 'uptime' as the closest available metric, which aligns with the expected output. It also ends with an offer to use uptime instead, matching the expected output's closing question. However, the actual output includes a large table of additional metrics and extended explanations that are unsupported additions not present in the expected output. While not contradictory, these additions go beyond the concise framing required, and the evaluation steps penalize unsupported additions. The core answer is present and accurate, but the verbosity and extra detail diverge from the expected minimal, direct response.
- Agent-reported duration: `9.886s`
- Agent tokens: `12,043`
- Agent cost: `$0.0359778`
- Tool calls: `3`
- Judge tokens: not reported separately
- Judge cost: not reported separately

### kwwhat run notes

- The agent read `repos/kwwhat/models/semantic/semantic_models.yml` and searched for
  `*availability*` (no matches).
- Correctness passed despite penalizing the extra metrics table — the core reference
  behavior (undefined metric → suggest uptime) matched.
- The same input was evaluated in a separate Plan A prototype run (`q003` in
  `rag_triad_plan.MD`) and failed Contextual Relevancy and Answer Relevancy. Because
  the agent outputs came from separate runs, this is illustrative evidence, not a
  controlled A/B comparison.
