FROM python:3.12-slim

RUN pip install --no-cache-dir \
    "nao-core==0.0.59" \
    "dbt-core==1.10.9" \
    "dbt-duckdb>=1.9.0" \
    "dbt-mcp"

WORKDIR /app

COPY nao_config.yaml .
COPY mcp.json agent/mcps/mcp.json
COPY profiles.yml /profiles/profiles.yml
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
