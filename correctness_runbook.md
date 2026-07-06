# Plan B: Correctness Prototype Runbook

Operational steps for running Plan B against the kwwhat `chat-bi` demo. This is demo
plumbing, not part of the measurement-strategy proposal.

## Prerequisites

- Docker Desktop is running.
- A local nao checkout is available to build a local nao image.
- `demo/.env` exists and contains `ANTHROPIC_API_KEY`.
- Ports `5005` and `8005` are free, or the previous demo container is stopped.
- Run commands from `demo/` unless stated otherwise.

## Build Images

```bash
# From any directory: build local nao
docker build -t getnao/nao:local /path/to/nao

# From demo/: rebuild chat-bi (also required after any golden_dataset.jsonl edit —
# eval cases are copied into the image, not bind-mounted)
docker compose build chat-bi
```

## Start the Stack

```bash
docker compose up duckdb-init
docker compose up dbt            # wait for exit code 0 and analytics.duckdb
docker compose up -d --force-recreate chat-bi
docker compose ps chat-bi        # expect 0.0.0.0:5005 and 0.0.0.0:8005
```

If your local nao requires auth, sign in at `http://localhost:5005` first, or pass
`--username`/`--password` (or `NAO_USERNAME`/`NAO_PASSWORD`) for non-interactive runs.

## Verify the CLI

```bash
docker compose exec chat-bi nao evals --help
# or, if chat-bi is not running:
docker compose run --rm --entrypoint nao chat-bi evals --help
```

## Run Evals

```bash
# One case
docker compose exec chat-bi bash -lc \
  "cd /app/kwwhat && nao evals -s q001 -m anthropic:claude-sonnet-4-6 --judge-model claude-sonnet-4-6 --timeout 30"

# Availability-index case
docker compose exec chat-bi bash -lc \
  "cd /app/kwwhat && nao evals -s q002 -m anthropic:claude-sonnet-4-6 --judge-model claude-sonnet-4-6 --timeout 120"

# All cases (use -T for CI / no TTY)
docker compose exec -T chat-bi bash -lc \
  "cd /app/kwwhat && nao evals -m anthropic:claude-sonnet-4-6 --judge-model claude-sonnet-4-6 --timeout 120"
```

Reports are persisted on the host via the `tests/outputs` mount:

```bash
ls -lt /path/to/kwwhat/demo/chat-bi/tests/outputs
```

## Operational Troubleshooting

Because these evals depend on a long-running Docker demo, most local failures are
operational rather than metric failures.

### Ports 5005 / 8005 Already in Use

```bash
docker ps --format "table {{.ID}}\t{{.Image}}\t{{.Ports}}\t{{.Names}}"
docker compose down --remove-orphans      # or: docker stop <container-id>
docker compose up -d --force-recreate chat-bi
```

### Container Running Old Code or Old Eval Cases

`golden_dataset.jsonl` and the nao CLI are baked into images. Rebuild in order:

```bash
docker build -t getnao/nao:local /path/to/nao
docker compose build chat-bi
docker compose up -d --force-recreate chat-bi
```

### `chat-bi` Waits Forever for `analytics.duckdb`

Build the data layer before starting chat:

```bash
docker compose up duckdb-init
docker compose up dbt
docker compose logs --tail 120 dbt
```

### `nao evals` Appears Stuck

Always pass `--timeout`. To stop a stuck process and check for a report:

```bash
docker compose exec chat-bi pkill -f "nao evals"
ls -lt /path/to/kwwhat/demo/chat-bi/tests/outputs
```

### `500 The selected model could not be resolved`

A model configuration problem, not a correctness failure. Use a model the backend can
resolve, e.g. `-m anthropic:claude-sonnet-4-6`.

### Unauthorized / Login Prompt

Sign in at `http://localhost:5005`, or pass `--username`/`--password` (or
`NAO_USERNAME`/`NAO_PASSWORD`).

### Backend or SQL Errors

Backend errors are recorded as `error_type: "backend_error"` and produce a non-zero
exit. Inspect logs before treating them as answer-quality failures:

```bash
docker compose logs --tail 200 chat-bi
```

Common causes: data pipeline not finished, agent queried a missing catalog/table, or
missing/invalid provider credentials.

### Docker Warning About `BETTER_AUTH_URL`

Expected. `BETTER_AUTH_URL` is a URL, not a secret; the scanner warns on the `AUTH`
substring. It does not block the build.
