#!/bin/bash
set -e

ANALYTICS_DB="/data/analytics.duckdb"

echo "=== kwwhat Chat BI ==="

echo "Waiting for analytics.duckdb to be ready..."
until [ -f "$ANALYTICS_DB" ]; do
  sleep 2
done
echo "analytics.duckdb is ready."

mkdir -p /app/kwwhat/repos /app/kwwhat/databases
echo "Syncing nao context (repos + database schemas)..."
cd /app/kwwhat
nao sync

echo ""
echo "==========================================="
echo "  kwwhat demo is ready!"
echo "  Ask me anything about your EV charger data."
echo "==========================================="
echo ""

exec /entrypoint.sh
