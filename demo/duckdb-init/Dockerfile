FROM python:3.12-slim

RUN pip install --no-cache-dir duckdb

WORKDIR /app
COPY init.py .

CMD ["python", "init.py"]
