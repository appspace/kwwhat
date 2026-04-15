"""
Service 1: DuckDB initializer.

Loads the kwwhat seed CSVs into a persistent DuckDB file at /data/raw.duckdb,
creating the RAW catalog with a SEED schema — matching kwwhat's dbt_project.yml vars:
  raw_database: RAW
  raw_schema:   SEED
"""

import duckdb
import os
import sys

RAW_DB_PATH = "/data/raw.duckdb"
SEEDS_DIR = "/seeds"

SEEDS = {
    "ocpp_1_6_synthetic_logs_14d": "ocpp_1_6_synthetic_logs_14d.csv",
    "ports": "ports.csv",
}


def main():
    print("=== DuckDB init: loading seed data ===")

    # Verify seed files are present before starting
    for table, filename in SEEDS.items():
        path = os.path.join(SEEDS_DIR, filename)
        if not os.path.exists(path):
            print(f"ERROR: seed file not found: {path}")
            sys.exit(1)
        print(f"  found {filename}")

    os.makedirs("/data", exist_ok=True)

    con = duckdb.connect(RAW_DB_PATH)

    con.execute("CREATE SCHEMA IF NOT EXISTS SEED")

    for table, filename in SEEDS.items():
        path = os.path.join(SEEDS_DIR, filename)
        con.execute(f"""
            CREATE OR REPLACE TABLE SEED.{table} AS
            SELECT * FROM read_csv_auto('{path}', header=true)
        """)
        count = con.execute(f"SELECT COUNT(*) FROM SEED.{table}").fetchone()[0]
        print(f"  loaded SEED.{table}: {count:,} rows")

    con.close()
    print(f"=== Done. Database written to {RAW_DB_PATH} ===")


if __name__ == "__main__":
    main()
