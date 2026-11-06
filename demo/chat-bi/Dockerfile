FROM nao:study

COPY nao_config.yaml /app/kwwhat/nao_config.yaml
COPY RULES.md /app/kwwhat/RULES.md
COPY tests/ /app/kwwhat/tests/
COPY entrypoint.sh /demo-entrypoint.sh
COPY arm/ /app/kwwhat/
RUN chmod +x /demo-entrypoint.sh

ENTRYPOINT ["/demo-entrypoint.sh"]
