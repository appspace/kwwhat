FROM python:3.12-slim

RUN apt-get update && apt-get install -y curl socat && rm -rf /var/lib/apt/lists/*

# dbt with DuckDB adapter, pinned to match the project's venv
RUN pip install --no-cache-dir \
    "dbt-core==1.10.9" \
    "dbt-duckdb>=1.9.0" \
    "dbt-metricflow" \
    "dbt-mcp"

WORKDIR /kwwhat

COPY profiles.yml /profiles/profiles.yml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV DBT_PROFILES_DIR=/profiles

ENTRYPOINT ["/entrypoint.sh"]
