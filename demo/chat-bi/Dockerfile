ARG NAO_BASE_IMAGE=getnao/nao:local
FROM ${NAO_BASE_IMAGE}

COPY nao_config.yaml /app/kwwhat/nao_config.yaml
COPY RULES.md /app/kwwhat/RULES.md
COPY tests/ /app/kwwhat/tests/
COPY entrypoint.sh /demo-entrypoint.sh
RUN chmod +x /demo-entrypoint.sh

ENTRYPOINT ["/demo-entrypoint.sh"]
