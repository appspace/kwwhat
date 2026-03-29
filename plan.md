  Execution Plan: kwwhat Demo with Docker Compose

  Architecture

                   ┌──────── shared Docker volume ─────────┐
                   │  /data/raw.duckdb   /data/analytics.duckdb  │
                   └──────┬──────────────────┬──────────────┘
                          │                  │
            ┌─────────────▼──┐   ┌───────────▼──────────┐   ┌────────────────────┐
            │  Service 1     │   │  Service 2            │   │  Service 3         │
            │  duckdb-init   │──▶│  dbt-core             │──▶│  chat-bi           │
            │  (init ctnr)   │   │  + dbt-mcp (MCP srv)  │   │  nao-core          │
            └────────────────┘   └───────────────────────┘   └────────────────────┘
            Loads CSV seeds         dbt build → exposes       MCP + DuckDB
            into raw.duckdb         MCP (HTTP/SSE :8080)      analytics.duckdb

  ---
  Phase 1 — Create demo directory structure

  Create /demo inside kwwhat with the following layout:

  demo/
  ├── docker-compose.yml
  ├── .env.example
  ├── run-demo.sh
  ├── duckdb-init/
  │   ├── Dockerfile
  │   └── init.py
  ├── dbt/
  │   ├── Dockerfile
  │   ├── profiles.yml
  │   └── entrypoint.sh
  └── chat-bi/
      ├── Dockerfile
      ├── nao_config.yaml
      ├── mcp.json
      └── entrypoint.sh

  ---
  Phase 2 — Service 1: duckdb-init (init container)

  Goal: Populate /data/raw.duckdb with seed CSV data so dbt can read from RAW.SEED.*.

  - Base image: python:3.12-slim
  - Installs: duckdb (Python package)
  - Mounts: ../seeds:/seeds:ro (kwwhat's CSV seed files), duckdb-data:/data
  - init.py creates raw.duckdb, attaches it as catalog RAW, creates schema SEED, loads:
    - RAW.SEED.ocpp_1_6_synthetic_logs_14d from ocpp_1_6_synthetic_logs_14d.csv
    - RAW.SEED.ports from ports.csv
  - Exits 0 when done (docker-compose service_completed_successfully condition)

  ---
  Phase 3 — Service 2: dbt (dbt-core + dbt-mcp)

  Goal: Run dbt build against DuckDB, write marts to ANALYTICS, then serve as MCP endpoint.

  - Base image: python:3.12-slim
  - Installs: dbt-duckdb, dbt-mcp (via pip/uvx)
  - Mounts: ../:/kwwhat:ro, duckdb-data:/data
  - profiles.yml configured with:
    - Main path: /data/analytics.duckdb (target database ANALYTICS)
    - attach: /data/raw.duckdb as alias RAW
  - entrypoint.sh:
    a. Wait for /data/raw.duckdb to exist
    b. dbt deps
    c. dbt build (seed is skipped — seeds already loaded by Service 1 into RAW)
    d. dbt-mcp in HTTP/SSE mode on :8080, local mode (no dbt Cloud)
  - Healthcheck: HTTP GET :8080 responds
  - Exposes port 8080

  Key config for dbt-mcp local mode:
  DISABLE_REMOTE=true
  DISABLE_SEMANTIC_LAYER=true  (no SL in local DuckDB)
  DBT_PROJECT_DIR=/kwwhat
  DBT_PROFILES_DIR=/kwwhat/demo/dbt

  ---
  Phase 4 — Service 3: chat-bi (nao-core)

  Goal: Interactive chat BI connected to mart models in DuckDB, using dbt-core as MCP.

  - Base image: python:3.12-slim
  - Installs: nao-core==0.0.59
  - Mounts: duckdb-data:/data
  - nao_config.yaml: DuckDB connection to /data/analytics.duckdb, schema main, include fact_* and dim_* —
  requires verifying nao supports DuckDB (currently only Snowflake in kwwhat-chat-BI — this is the biggest
  open question)
  - mcp.json: connects to Service 2 MCP via HTTP/SSE http://dbt:8080/sse
  - entrypoint.sh: wait for Service 2 healthcheck → nao chat
  - stdin_open: true, tty: true (interactive terminal)

  ---
  Phase 5 — docker-compose.yml

  services:
    duckdb-init:
      build: ./duckdb-init
      volumes: [duckdb-data:/data, ../seeds:/seeds:ro]

    dbt:
      build: ./dbt
      depends_on:
        duckdb-init: { condition: service_completed_successfully }
      volumes: [duckdb-data:/data, ../:/kwwhat:ro]
      ports: ["8080:8080"]
      healthcheck: { test: curl http://localhost:8080 }

    chat-bi:
      build: ./chat-bi
      depends_on:
        dbt: { condition: service_healthy }
      volumes: [duckdb-data:/data]
      stdin_open: true
      tty: true

  volumes:
    duckdb-data:

  ---
  Phase 6 — run-demo.sh

  Orchestration script:
  1. docker compose build
  2. docker compose up duckdb-init (wait for completion)
  3. docker compose up dbt -d (background, wait for healthy)
  4. docker compose run --rm chat-bi (interactive session)
  5. Teardown instructions

  ---
  Open Questions to Resolve During Build

  ┌─────┬───────────────────────────────────┬────────────────────┬───────────────────────────────────────┐
  │  #  │             Question              │       Impact       │                 Plan                  │
  ├─────┼───────────────────────────────────┼────────────────────┼───────────────────────────────────────┤
  │     │ Does nao-core support DuckDB as a │                    │ Check nao docs; fallback: query       │
  │ 1   │  database type?                   │ Service 3 design   │ DuckDB via execute_sql through MCP    │
  │     │                                   │                    │ only                                  │
  ├─────┼───────────────────────────────────┼────────────────────┼───────────────────────────────────────┤
  │     │ Does dbt-mcp support HTTP/SSE     │ Service 2↔3        │ If not: merge dbt-mcp into chat-bi    │
  │ 2   │ transport (not just stdio)?       │ communication      │ container or use stdio via Docker     │
  │     │                                   │                    │ exec                                  │
  ├─────┼───────────────────────────────────┼────────────────────┼───────────────────────────────────────┤
  │     │ Does dbt-mcp work in local mode   │ Service 2          │ Check env vars; fallback: expose dbt  │
  │ 3   │ (no dbt Cloud, no Semantic        │ functionality      │ via a thin HTTP wrapper               │
  │     │ Layer)?                           │                    │                                       │
  └─────┴───────────────────────────────────┴────────────────────┴───────────────────────────────────────┘

  ---
  Files NOT changing

  The kwwhat dbt project itself (models/, seeds/, dbt_project.yml, etc.) stays untouched. The demo is
  entirely self-contained in demo/.
