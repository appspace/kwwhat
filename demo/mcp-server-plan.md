# kWwhat MCP Context Server — Implementation Plan

A web MCP server exposing three narrow context tools (`get_driver`, `get_charger`,
`get_charge_attempt`) to any MCP-compatible client (Claude Desktop, MCP Inspector, calling
agent backends). Deployed as **Service 4** alongside the existing demo stack: duckdb, dbt, nao chat.

---

## 1. Where it fits

```
duckdb-init  →  dbt  →  analytics.duckdb
                                │
                       ┌────────┴────────┐
                       │                 │
                   chat-bi           mcp-server        ← NEW (Service 4)
                (nao, port 5005)    (FastAPI, port 8080)
```

`mcp-server` reads from the same `analytics.duckdb` volume the `dbt` service writes.
It does not write to the database. It starts only after `dbt` completes.

---

## 2. Data layer — what exists and what still needs seeding

`dim_drivers` (PR #108) is assumed in place. Its grain is one row per distinct RFID
`id_tag` observed in OCPP charge attempts, with a surrogate `driver_key`.

**Fields available now** (from `dim_drivers`):

| Field in `get_driver` outputSchema | Source |
|------------------------------------|--------|
| `driver_id` | `driver_key` (surrogate) |
| `is_known_driver` | `dim_drivers.is_known_driver` |
| `latest_authorization_status` | `dim_drivers.latest_authorization_status` |
| `first_seen_ts` / `last_seen_ts` | `dim_drivers.first_seen_ts` / `last_seen_ts` |

**Fields deferred until CRM data is in place** (see open questions):

| Field | What's needed |
|-------|--------------|
| `vehicle.make` | CRM driver profile |
| `vehicle.model` | CRM driver profile |
| `vehicle.connector_type` | CRM driver profile |

`get_driver` ships without vehicle data for now and returns only what `dim_drivers`
provides. Vehicle fields are added once a CRM source is available.

**One remaining seed gap:**

| Gap | Proposed fix |
|-----|-------------|
| Charger hardware attributes (model, firmware, power_kw) | New seed: `demo/seeds/charger_profiles.csv` keyed on `charge_point_id` |

Charger seed data is synthetic and demo-only. The MCP server queries a mart table or
joined view built on top of it — it does not query the seed directly.

---

## 3. Transport and protocol

Use **Streamable HTTP** (MCP spec 2025-11-25). A single `POST /mcp` endpoint handles
all JSON-RPC messages; the server may optionally upgrade to SSE for streaming responses.
This is the current recommended transport for web-hosted MCP servers and is supported by
Claude Desktop and the MCP Inspector.

After the `initialize` handshake, every subsequent `POST /mcp` request must include the
`MCP-Protocol-Version` header set to the negotiated version string (e.g. `2025-11-25`).
The server must reject requests that omit or mismatch this header with HTTP 400.

The server must return HTTP 403 for requests with an invalid or unexpected `Origin` header
(CSRF protection per the spec).

Endpoint surface:

```
POST /mcp                   ← all MCP JSON-RPC (initialize, tools/call, tools/list, …)
POST /oauth/token           ← testing auth: client_credentials token exchange
GET  /health                ← liveness probe (no auth required)
```

---

## 4. Authentication — two modes

### Mode A: OAuth 2.0 Client Credentials (testing / Claude Desktop)

Intended for Claude Desktop and the MCP Inspector during development and demos.

Flow:
1. Operator provisions a `CLIENT_ID` + `CLIENT_SECRET` pair (set via env vars).
2. Client posts to `POST /oauth/token` with `Content-Type: application/x-www-form-urlencoded`
   and form fields `grant_type=client_credentials`, `client_id`, `client_secret`:
   ```sh
   curl -X POST "$SERVER_URL/oauth/token" \
     -H "Content-Type: application/x-www-form-urlencoded" \
     -d "grant_type=client_credentials" \
     -d "client_id=$CLIENT_ID" \
     -d "client_secret=$CLIENT_SECRET"
   ```
3. Server returns a short-lived JWT access token (default TTL: 1 hour).
4. Client attaches `Authorization: Bearer <token>` to every `POST /mcp` request.
5. Server validates the JWT signature and expiry on each request.

No user-facing consent screen; this is machine-to-machine only.
Tokens are signed with a `JWT_SECRET` env var (HS256). In production, replace with
an asymmetric key pair.

Production note: the 2025-06-18 spec classifies MCP servers as OAuth Resource Servers
and requires clients to implement Resource Indicators ([RFC 8707](https://www.rfc-editor.org/rfc/rfc8707.html)).
The 2025-11-25 spec additionally recommends **OAuth Client ID Metadata Documents** as
the dynamic client registration mechanism — the demo's static env-var credentials are a
shortcut; a production deployment should serve a `client_id` metadata document.

### Mode B: Shared Secret (production server-to-server)

Intended for trusted backend callers in a server-to-server context.

Flow:
1. Operator provisions an `API_KEY` (set via env var). The key must be alphanumeric
   (`[A-Za-z0-9]`) — HTTP header values have encoding constraints and alphanumeric is
   the safest subset. Recommended length: 32+ characters.
2. Client attaches `Authorization: Bearer <api_key>` to every `POST /mcp` request.
3. Server validates the key format on startup (reject non-alphanumeric at boot, not at
   request time) and compares the header value to `API_KEY` using a constant-time
   comparison.

No token exchange needed. Simpler; appropriate when the caller is a controlled backend,
not a desktop tool.

### Auth mode selection

Both modes are active simultaneously. The server accepts either a valid JWT (Mode A)
or the raw `API_KEY` (Mode B) on the same `Authorization: Bearer` header.
Mode is determined by whether the value parses as a JWT.

The `/oauth/token` endpoint is only relevant for Mode A.

---

## 5. ID validation and PII rejection

Validated on entry to every tool call, before any database query.

IDs are passed as-is from the underlying data model — no prefix scheme. Validation
is limited to:
- Non-empty string.
- No `@`, spaces, or other common PII signals (basic heuristic; production would be stricter).
- Exceeds 64 characters → reject.

Return a **tool execution error** (`isError: true` in the tool result, with a descriptive
`content[0].text` message) for invalid input — not an HTTP 400 or a JSON-RPC protocol
error. The 2025-06-18 spec requires this so the model can read the error and self-correct
(e.g. retry with a valid ID format). Do not log the rejected value.

---

## 6. Tool output contract

Every tool returns **both** `structuredContent` (machine-readable, validated against
`outputSchema`) and a `content[0].text` block (natural-language summary the model can
always read). They must be consistent — the text is a faithful summary of the structured
data, not a separate source of truth.

A missing record is **not** an error. It returns `{"found": false}` in `structuredContent`
and a plain "No X found for ID Y" text block, with HTTP 200 and MCP success.

---

## 7. Tool definitions

The description field carries the weight — the agent decides whether to call a tool
almost entirely from it. Each description states what the tool returns and includes a
"Call this when…" trigger condition rather than leaving the model to guess.

```json
{
  "name": "get_driver",
  "description": "Retrieve non-identifying attributes for a driver by their kWwhat driver ID. Returns vehicle profile — NO PII (no name, email, phone, or address). Call this when the agent needs context about who is on the call to tailor support or understand the driver's setup. Requires a valid driver ID obtained earlier in the call.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "The kWwhat driver ID (opaque identifier). Not a phone number, email, or name."
      }
    },
    "required": ["id"],
    "additionalProperties": false
  }
}
```

```json
{
  "name": "get_charger",
  "description": "Retrieve technical and status attributes for a charger by its ID. Returns model, connector types, power rating, current operational status (available/in-use/faulted/offline), firmware version, and last-seen timestamp. Call this when diagnosing a charging problem, confirming a charger's capabilities, or checking whether a unit is reachable. Does not return location PII tied to a private residence.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "The charger ID (opaque identifier)."
      }
    },
    "required": ["id"],
    "additionalProperties": false
  }
}
```

```json
{
  "name": "get_charge_attempt",
  "description": "Retrieve details for a charge attempt by its ID. Returns start/end time, energy delivered (kWh), session state (active/completed/interrupted/errored), associated charger ID, and error codes if any. Call this to investigate a specific charge — e.g. 'my last session failed'. Returns the charger and driver IDs so the agent can chain to get_charger or get_driver if more context is needed.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "id": {
        "type": "string",
        "description": "The charge attempt ID (opaque identifier)."
      }
    },
    "required": ["id"],
    "additionalProperties": false
  }
}
```

---

## 8. Stack

| Layer | Choice | Reason |
|-------|--------|--------|
| Language | Python 3.12 | Consistent with dbt ecosystem; existing demo uses Python |
| Framework | FastAPI | Native async, first-class Pydantic, OpenAPI docs included |
| MCP SDK | `mcp[server]` (official Python SDK) | Handles JSON-RPC protocol, `outputSchema`, `structuredContent` |
| Database | `duckdb` Python package | Same DB the `dbt` service writes; read-only connection |
| Auth / JWT | `python-jose[cryptography]` | Lightweight JWT signing/validation |
| Validation | Pydantic v2 models | Already a FastAPI dependency |

---

## 8. File structure

```
demo/
└── mcp/
    ├── Dockerfile
    ├── requirements.txt
    ├── app/
    │   ├── main.py            # FastAPI app; mounts MCP endpoint and /oauth/token
    │   ├── auth.py            # JWT issue/validate + API key check; mode selection
    │   ├── validation.py      # PII heuristics
    │   ├── db.py              # DuckDB read-only connection; query helpers
    │   ├── tools/
    │   │   ├── __init__.py
    │   │   ├── get_driver.py  # tool definition + query + response builder
    │   │   ├── get_charger.py
    │   │   └── get_charge_attempt.py
    │   └── models/
    │       ├── driver.py      # Pydantic output models mirroring outputSchema
    │       ├── charger.py
    │       └── charge_attempt.py
    └── tests/
        ├── test_auth.py
        ├── test_tools.py      # happy path + not-found + invalid ID per tool
        └── test_rate_limit.py
```

---

## 9. Docker integration

Add Service 4 to `docker-compose.yml`:

```yaml
  mcp:
    build: ./mcp
    depends_on:
      dbt:
        condition: service_completed_successfully
    volumes:
      - duckdb-data:/data:ro        # read-only; dbt owns the write
    ports:
      - "8080:8080"
    environment:
      - JWT_SECRET=${JWT_SECRET}
      - API_KEY=${API_KEY}
      - CLIENT_ID=${MCP_CLIENT_ID}
      - CLIENT_SECRET=${MCP_CLIENT_SECRET}
      - DB_PATH=/data/analytics.duckdb
```

Add to `.env.example`:

```
JWT_SECRET=change-me-in-production
API_KEY=change-me-in-production
MCP_CLIENT_ID=kwwhat-demo
MCP_CLIENT_SECRET=change-me-in-production
```

---

## 10. Claude Desktop config (testing with Mode A)

Once running locally, add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "kwwhat": {
      "type": "http",
      "url": "http://localhost:8080/mcp",
      "oauth": {
        "tokenUrl": "http://localhost:8080/oauth/token",
        "clientId": "<MCP_CLIENT_ID>",
        "clientSecret": "<MCP_CLIENT_SECRET>"
      }
    }
  }
}
```

---

## 11. Demo README update

Add an "MCP server" section to `demo/README.md` covering:
- What it is and when to use it (alternative to chat-bi for agent/API access)
- How to point Claude Desktop at it
- The three tools and the chaining pattern (`get_charge_attempt` → `get_charger` / `get_driver`)
- The two auth modes and when to use each

---

## 12. Open questions

| # | Question | Why it matters |
|---|----------|---------------|
| 1 | When CRM data lands, what is the join key between the CRM driver record and `dim_drivers`? | Determines whether `id_tag` maps directly to a CRM ID or needs a separate identity resolution step |
| 2 | Desired token TTL for Claude Desktop testing? | 1 hour is the draft default — fine for demos, may need to be shorter for security reviews |
| 3 | Should the MCP server be included in `run-demo.sh` by default, or started separately? | Starting it by default adds the env var requirement; some users may not have credentials |

---

## 13. Rate limiting (optional)

Applied per authenticated identity (token sub / api key hash), not per IP, so shared
infrastructure on the caller's side is not penalised.

| Tier | Limit |
|------|-------|
| Default (any valid credential) | 60 requests / minute |
| Burst | 10 requests / second |

Implemented with `slowapi` (Starlette middleware) using an in-memory sliding window
(sufficient for a single-process demo). Add `slowapi` to `requirements.txt` and a
`rate_limit.py` module only if this is needed.
Headers returned: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`.
Exceed limit → `429 Too Many Requests`.

Production note: replace with Redis-backed rate limiting for multi-instance deployments.
