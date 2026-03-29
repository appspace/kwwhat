# kwwhat demo

Run the full kwwhat analytics pipeline locally — no cloud account needed.

This demo spins up three services via Docker Compose:

| Service | What it does |
|---------|-------------|
| `duckdb-init` | Loads the sample OCPP log data into a local database |
| `dbt` | Runs the kwwhat dbt pipeline, transforming raw logs into analytics tables |
| `chat-bi` | Opens an AI chat interface so you can ask questions about the data |

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
- An [Anthropic API key](https://console.anthropic.com/) (powers the chat interface)

---

## Quickstart

```bash
# 1. Copy the environment template and add your API key
cp .env.example .env
# edit .env and set ANTHROPIC_API_KEY=...

# 2. Run the demo
./run-demo.sh
```

That's it. The script will build the images, load the data, run the pipeline, and drop you into the chat interface.

---

## What happens under the hood

```
seeds/                          demo/
ocpp_1_6_synthetic_logs_14d.csv  ──▶  duckdb-init  ──▶  raw.duckdb
ports.csv                                                    │
                                                             ▼
                                                           dbt build
                                                             │
                                                             ▼
                                                      analytics.duckdb
                                                      (fact_*, dim_*)
                                                             │
                                                             ▼
                                                          nao chat
```

1. **duckdb-init** reads the two CSV files in `seeds/` and loads them into `raw.duckdb` — a file that acts as the raw data warehouse.
2. **dbt** picks up from there, runs all the staging → intermediate → mart models, and writes the results to `analytics.duckdb`.
3. **chat-bi** connects to both the analytics database and the dbt service, so you can ask plain-English questions like:
   - *"Report on reliability of my EV charging network"*
   - *"What was the charge attempt success rate last week?"*
   - *"Which chargers had the most downtime?"*
   - *"Show me visit success by location."*

---

## Sample data

The `seeds/` folder contains synthetic OCPP 1.6 logs donated for this project:

| File | Contents |
|------|----------|
| `ocpp_1_6_synthetic_logs_14d.csv` | 14 days of synthetic EV charger messages (~2 MB) |
| `ports.csv` | Reference data: charger ports, connector types, and commission dates |

---

## Manual commands

If you prefer to run services individually:

```bash
# Build images
docker compose build

# Load seed data (runs once and exits)
docker compose up duckdb-init

# Run dbt pipeline and start MCP server (background)
docker compose up -d dbt

# Open chat interface (interactive)
docker compose run --rm chat-bi

# Stop everything
docker compose down

# Stop and wipe the database volume
docker compose down -v
```

---

## Project structure

```
demo/
├── README.md
├── docker-compose.yml
├── run-demo.sh
├── .env.example
├── seeds/                  ← sample OCPP CSV data
├── duckdb-init/            ← Service 1: loads seeds into raw.duckdb
├── dbt/                    ← Service 2: dbt build + MCP server
└── chat-bi/                ← Service 3: nao chat interface
```
