#!/bin/bash
set -e

ANALYTICS_DB="/data/analytics.duckdb"

echo "=== kwwhat Chat BI ==="

# Wait for analytics.duckdb to exist (written by the dbt service)
echo "Waiting for analytics.duckdb to be ready..."
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
mkdir -p repos databases
echo "Syncing nao context (repos + database schemas)..."
nao sync
echo ""
exec nao chat
