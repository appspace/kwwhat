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
dbt deps --log-path /tmp/dbt-logs

echo "Running dbt run (staging → intermediate → marts)..."
dbt run --target duckdb --log-path /tmp/dbt-logs

echo "Running dbt tests (failures reported but do not block startup)..."
dbt test --target duckdb --log-path /tmp/dbt-logs --exclude "test_type:unit" || echo "Some tests failed — see logs."

echo "=== dbt build complete ==="
