#!/bin/bash
set -e

ANALYTICS_DB="/data/analytics.duckdb"
DBT_MCP_URL="http://dbt:8080"

echo "=== kwwhat Chat BI ==="

# Wait for dbt to finish building and the MCP server to be up
echo "Waiting for dbt to finish building analytics models..."
until curl -sf "$DBT_MCP_URL" > /dev/null 2>&1; do
  echo "  dbt not ready yet, waiting..."
  sleep 5
done
echo "dbt MCP server is up."

# Wait for the analytics database to exist
until [ -f "$ANALYTICS_DB" ]; do
  sleep 2
done
echo "analytics.duckdb is ready."

echo ""
echo "==========================================="
echo "  kwwhat demo is ready!"
echo "  Ask me anything about your EV charger data."
echo "==========================================="
echo ""

cd /app
exec nao chat
