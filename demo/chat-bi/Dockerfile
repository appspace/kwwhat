FROM python:3.12-slim

RUN pip install --no-cache-dir \
    "nao-core[duckdb]==0.0.59"

WORKDIR /app

COPY nao_config.yaml .
COPY RULES.md .
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
