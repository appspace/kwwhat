#!/bin/bash
set -e

RAW_DB="/data/raw.duckdb"

echo "=== dbt service starting ==="

# Wait for Service 1 to finish loading the seed data
echo "Waiting for raw.duckdb to be ready..."
until [ -f "$RAW_DB" ]; do
  sleep 2
done
echo "raw.duckdb found."

cd /kwwhat

echo "Installing dbt packages..."
dbt deps

echo "Running dbt build (staging → intermediate → marts)..."
dbt build --target duckdb

echo "=== dbt build complete ==="

# Configure dbt-mcp for local mode:
#   - no dbt Cloud (DISABLE_REMOTE=true)
#   - Semantic Layer via local MetricFlow (DISABLE_SEMANTIC_LAYER=false)
#   - Discovery API enabled so nao can browse model metadata
#   - SQL execution enabled so nao can run queries
export DBT_PROJECT_DIR=/kwwhat
export DBT_PROFILES_DIR=/profiles
export DISABLE_REMOTE=true
export DISABLE_SEMANTIC_LAYER=false
export DISABLE_DISCOVERY=false
export DISABLE_SQL=false
export DISABLE_ADMIN_API=true

echo "Starting dbt-mcp server on port 8080 (Semantic Layer enabled)..."
exec python -m dbt_mcp --transport sse --port 8080
