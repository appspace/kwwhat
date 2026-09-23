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

# dbt build loads seeds, runs models and runs data tests in DAG order.
# Any failure exits non-zero so run-demo.sh stops before starting chat BI.
echo "Running dbt build (seeds, staging, intermediate, marts, tests)..."
dbt build --target duckdb --full-refresh --log-path /tmp/dbt-logs --exclude "test_type:unit"

echo "=== dbt build complete ==="
