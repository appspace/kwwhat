#!/bin/bash
# kwwhat demo launcher
# Starts all three services and drops you into the chat BI interface.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Pre-flight checks ────────────────────────────────────────────────────────

if ! command -v docker &> /dev/null; then
  echo "ERROR: Docker is not installed. Please install Docker Desktop first."
  exit 1
fi

if [ ! -f ".env" ]; then
  echo "ERROR: .env file not found."
  echo "  Copy .env.example to .env and add your ANTHROPIC_API_KEY."
  exit 1
fi

source .env

if [ -z "$ANTHROPIC_API_KEY" ]; then
  echo "ERROR: ANTHROPIC_API_KEY is not set in .env"
  exit 1
fi

# ── Build images ─────────────────────────────────────────────────────────────

echo ""
echo "Building Docker images (this may take a few minutes on first run)..."
docker compose build

# ── Start Services 1 & 2 ────────────────────────────────────────────────────

echo ""
echo "Step 1/3: Loading seed data into DuckDB..."
docker compose up duckdb-init

echo ""
echo "Step 2/3: Running dbt build (staging → intermediate → marts)..."
echo "          This transforms raw OCPP logs into analytics tables."
echo "          (This can take 1-2 minutes)"
docker compose up -d dbt

echo ""
echo "Waiting for dbt to finish and start the MCP server..."
docker compose up dbt --wait 2>/dev/null || true

# ── Launch chat BI ───────────────────────────────────────────────────────────

echo ""
echo "Step 3/3: Starting chat BI interface..."
echo ""
docker compose run --rm -p 5005:5005 -p 8005:8005 chat-bi

# ── Cleanup prompt ───────────────────────────────────────────────────────────

echo ""
echo "Demo session ended."
echo ""
echo "To stop all services:    docker compose down"
echo "To wipe the data volume: docker compose down -v"
