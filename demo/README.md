# kwwhat demo

Run the full kwwhat analytics pipeline locally — no cloud account needed.

<img
  alt="demo screenshot showing ChatBI interface" 
  src="https://github.com/user-attachments/assets/95010112-11c3-4c51-b77d-8ea3dcc10053"
style="width: 100%; height: auto;"
/>

---

## Quickstart

```bash
# 1. Copy the environment template and add your API key
cp .env.example .env
# edit .env and set ANTHROPIC_API_KEY=...

# 2. Run the demo
./run-demo.sh
```

That's it. The script will build the images, load the data, run the pipeline, and open the chat interface at **http://localhost:5005**.

---

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running
  
This demo spins up three services via Docker Compose:

| Service | What it does |
|---------|-------------|
| `duckdb-init` | Loads the sample OCPP log data into a local database |
| `dbt` | Runs the kwwhat dbt pipeline, transforming raw logs into analytics tables |
| `chat-bi` | Opens an AI chat interface so you can ask questions about the data |

- An [Anthropic API key](https://console.anthropic.com/) (powers the chat interface)

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

# Run dbt pipeline
docker compose up dbt

# Open chat interface (interactive) — available at http://localhost:5005
docker compose run --rm -p 5005:5005 -p 8005:8005 chat-bi

# Stop everything
docker compose down

# Stop and wipe the database volume
docker compose down -v
```

---

## Running tests

Tests live in `chat-bi/tests/` and run against the live chat server. With the demo already running, open a terminal and exec into the container:

```bash
docker exec -it $(docker ps -q --filter "publish=5005") bash
cd /app/kwwhat
nao test -m anthropic:claude-sonnet-4-6
```

You'll be prompted to log in with the account you created at http://localhost:5005. Results (pass/fail, tokens, cost, latency) are saved to `/app/kwwhat/tests/outputs/`.

You should see
```
                                             Test Results
┏━━━━━━━━━━━━━┳━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━━┳━━━━━━━━┳━━━━━━━━━━━┳━━━━━━━━━━┳━━━━━━━┓
┃ Test        ┃ Model                       ┃ Status ┃ Message ┃ Tokens ┃ Cost      ┃ Time (s) ┃ Tools ┃
┡━━━━━━━━━━━━━╇━━━━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━━╇━━━━━━━━╇━━━━━━━━━━━╇━━━━━━━━━━╇━━━━━━━┩
│ total_ports │ anthropic:claude-sonnet-4-6 │ ✓      │ match   │ 16253  │ 0.0246861 │ 12.2     │ 5     │
│             │                             │        │         │ 16253  │ $0.0247   │ 12       │ 5     │
└─────────────┴─────────────────────────────┴────────┴─────────┴────────┴───────────┴──────────┴───────┘
```

To add more tests, create a YAML file in `chat-bi/tests/`:

```yaml
name: my_test
prompt: "Your natural language question here"
sql: |
  SELECT ... -- reference query whose results the agent must match
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
