# Agent instructions

## IMPORTANT: Data access rules

**Never** run `information_schema` queries, `SHOW TABLES`, or any other schema introspection SQL. You already have everything you need:

- **What metrics exist**: read `models/semantic/semantic_models.yml` — it contains all metrics, measures, dimensions, and entities.
- **What tables to query**: read `models/marts/marts.yml` — it describes every mart table with column-level documentation. Only `fact_*` and `dim_*` tables in the `ANALYTICS` schema are available.
- **No other tables exist** for your purposes. Do not look for them.
