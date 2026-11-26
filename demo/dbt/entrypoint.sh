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

# A seed that starts after the default start_processing_date + incremental_window (dbt_project.yml)
# needs a later start, for example START_PROCESSING_DATE=2026-01-01 for the study's confirmatory seed.
# Unit tests run without it: their fixtures assume the default.
DBT_VARS=()
if [ -n "$START_PROCESSING_DATE" ]; then
  DBT_VARS=(--vars "{start_processing_date: '$START_PROCESSING_DATE'}")
fi

echo "Installing dbt packages..."
dbt deps --log-path /tmp/dbt-logs

echo "Running dbt seed..."
dbt seed --target duckdb "${DBT_VARS[@]}" --log-path /tmp/dbt-logs

echo "Running dbt run (staging → intermediate → marts)..."
dbt run --target duckdb "${DBT_VARS[@]}" --full-refresh --log-path /tmp/dbt-logs

echo "Running dbt tests (failures reported but do not block startup)..."
dbt test --target duckdb "${DBT_VARS[@]}" --log-path /tmp/dbt-logs --exclude "test_type:unit" || echo "Some tests failed — see logs."

echo "Running dbt unit tests (failures reported but do not block startup)..."
dbt test --target duckdb --log-path /tmp/dbt-logs --select "test_type:unit" || echo "Some unit tests failed — see logs."

echo "=== dbt build complete ==="
