# nao eval options: with and without code changes

**Prompt:** outline my options with touching nao and ABC without, add all details and summarise in a table like above

---

## Option 0: With nao code changes

There's one coherent set of changes, across 4 files:

### 1. Test case format — `cli/nao_core/commands/test/case.py`

Add an `evals` field to the YAML schema and `TestCase` dataclass. `sql` becomes fully optional alongside it:

```yaml
# tabular test (existing)
name: top_customers
prompt: "Top 5 customers by revenue"
sql: "SELECT customer, SUM(revenue) FROM orders GROUP BY 1 ORDER BY 2 DESC LIMIT 5"

# g-eval test (new)
name: reliability_report
prompt: "Report on reliability"
evals:
  - type: g-eval
    criteria: "The answer is specifically about EV charging reliability, not generic reliability"
    threshold: 0.7
```

```python
@dataclass
class GEvalConfig:
    criteria: str
    threshold: float = 0.7

@dataclass
class TestCase:
    name: str
    prompt: str
    file_path: Path
    sql: str | None = None          # was required, now optional
    evals: list[GEvalConfig] = field(default_factory=list)
```

### 2. G-Eval scorer + runner dispatch — `cli/nao_core/commands/test/runner.py`

Add `run_g_eval()` that calls an LLM judge, and dispatch in `run_test()` based on which fields are present:

```python
def run_g_eval(response_text: str, config: GEvalConfig) -> tuple[bool, float, str]:
    """Score response with G-Eval LLM judge. Returns (passed, score, reason)."""
    # Standard G-Eval prompt structure
    prompt = f"""You are evaluating an AI assistant's response.
Criteria: {config.criteria}

Response to evaluate:
{response_text}

Score from 0.0 to 1.0 how well the response meets the criteria.
Return JSON: {{"score": 0.0-1.0, "reason": "..."}}"""

    # call any LLM (openai, anthropic, etc.)
    ...
    passed = score >= config.threshold
    return passed, score, reason
```

`TestRunResult` gets `score: float | None` added. `run_test()` checks `test_case.evals` vs `test_case.sql` to decide which path to take. Both can coexist in one YAML.

### 3. Backend route — `apps/backend/src/routes/test.ts`

One line: make `sql` optional in the Zod schema:

```typescript
// before
sql: z.string(),

// after
sql: z.string().optional(),
```

The `if (sql)` branch already handles the absent case correctly — no other backend changes needed.

### 4. Client — `cli/nao_core/commands/test/client.py`

Only send `sql` when present:

```python
json={
    "model": {...},
    "prompt": test_case.prompt,
    **({"sql": test_case.sql} if test_case.sql else {}),
}
```

---

## Without nao code changes

### Option A — nao-core client + empty sql trick

Install `nao-core` (it's the same package the docker container runs). Import `AgentClient` directly and POST with `sql: ""` — empty string satisfies `z.string()` in Zod but is falsy in JS, so the verification branch is skipped and you get back just the text.

```python
import os
from nao_core.commands.test.client import AgentClient, TestCase
from pathlib import Path

os.environ["BACKEND_URL"] = "http://localhost:5005"
client = AgentClient(email="you@example.com", password="secret")

case = TestCase(name="reliability", prompt="Report on reliability", sql="", file_path=Path("."))
result = client.run_test(case)

response_text = result.text
# result also has: result.usage.totalTokens, result.cost.totalCost, result.duration_ms, result.tool_calls

# run G-Eval here — e.g. with deepeval:
from deepeval.metrics import GEval
from deepeval.test_case import LLMTestCase, LLMTestCaseParams

metric = GEval(
    name="Groundedness",
    criteria="The answer is specifically about EV charging reliability",
    evaluation_params=[LLMTestCaseParams.ACTUAL_OUTPUT],
)
test_case = LLMTestCase(input="Report on reliability", actual_output=response_text)
metric.measure(test_case)
print(metric.score, metric.reason)
```

Authentication is handled by nao-core's `get_auth_session` — it stores cookies to `~/.nao/auth.json` after the first login, so subsequent runs don't re-authenticate.

### Option B — post-process nao test JSON outputs

Run `nao test` normally (pointed at docker via env var), then score the saved JSON in a separate script. No custom client code needed.

```bash
BACKEND_URL=http://localhost:5005 nao test -m anthropic:claude-sonnet-4-6
```

This writes `tests/outputs/results_<timestamp>.json`. Each entry in `results[]` has:

```json
{
  "name": "reliability_report",
  "passed": true,
  "details": {
    "response_text": "EV charging reliability refers to...",
    "tool_calls": [],
    "actual_data": [],
    "expected_data": []
  }
}
```

Read and score:

```python
import json
from pathlib import Path

data = json.loads(Path("tests/outputs/results_20260429_230707.json").read_text())

for result in data["results"]:
    text = result["details"]["response_text"]
    # run G-Eval on text, append score back to result dict

# optionally write back in the same format so nao test server can display it
Path("tests/outputs/results_geval.json").write_text(json.dumps(data, indent=2))
```

`nao test server` will pick up the rewritten file and display it in the browser UI, though the score won't render in a dedicated column since the schema doesn't have one.

### Option C — direct chat API (streaming)

POST directly to `/api/agent`, parse the SSE stream, collect the full text. Persists the chat to the database and supports multi-turn conversations.

```python
import requests, json

session = requests.Session()
session.post("http://localhost:5005/api/auth/sign-in/email",
    json={"email": "you@example.com", "password": "secret"})

response = session.post(
    "http://localhost:5005/api/agent",
    json={
        "message": {"text": "Report on reliability"},
        "model": {"provider": "anthropic", "modelId": "claude-sonnet-4-6"},
        # omit chatId → new chat; include it → continue existing
    },
    stream=True,
)

full_text = []
chat_id = None

for line in response.iter_lines():
    if not line:
        continue
    line = line.decode()
    if line.startswith("0:"):                    # text delta
        full_text.append(json.loads(line[2:]))
    elif line.startswith("2:"):                  # data parts
        for part in json.loads(line[2:]):
            if part.get("type") == "newChat":
                chat_id = part["id"]             # save to continue this chat
    elif line.startswith("d:"):                  # stream done
        break

response_text = "".join(full_text)
# run G-Eval on response_text
```

---

## Summary table

| | **Option 0: With nao changes** | **Option A** | **Option B** | **Option C** |
|---|---|---|---|---|
| **nao code touched** | Yes — 4 files | No | No | No |
| **Eval defined in** | YAML test file | Your script | Your script | Your script |
| **G-Eval scoring** | Built into `nao test` | Your script | Your script | Your script |
| **Response format** | JSON | JSON | JSON (pre-saved) | SSE stream |
| **Persists to DB** | No | No | No | Yes |
| **Multi-turn support** | No | No | No | Yes |
| **Shows in `nao test server`** | Yes, natively | No | Partially (no score column) | No |
| **Needs nao-core installed** | Yes (it's the CLI) | Yes | Yes (to run `nao test`) | No |
| **Auth handling** | Built-in | Built-in (nao-core) | Built-in (nao-core) | Manual |
| **Usage/cost tracking** | Yes | Yes | Yes | Partial (in `a:` chunk) |
| **Complexity** | Medium (4 file edits) | Low | Low | Medium (stream parsing) |
| **Best for** | Shipping evals as a first-class feature | Quick one-off G-Eval scripts | Scoring runs you already have | Testing multi-turn conversations |
