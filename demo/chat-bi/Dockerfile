FROM getnao/nao:latest

COPY nao_config.yaml /app/example/nao_config.yaml
COPY RULES.md /app/example/RULES.md
COPY entrypoint.sh /demo-entrypoint.sh
RUN chmod +x /demo-entrypoint.sh

ENTRYPOINT ["/demo-entrypoint.sh"]
