# Rules

- Never run schema introspection queries (`information_schema`, `SHOW TABLES`, etc.). The available tables and their columns are already provided in your context.
- For metrics, measures, dimensions, and entities: use `repos/kwwhat/models/semantic/semantic_models.yml` as the authoritative source.
- For SQL: only query `fact_*` and `dim_*` tables in the `ANALYTICS` schema. Column documentation is in `repos/kwwhat/models/marts/marts.yml`.
- Do not make up metrics. If a metric is not defined in the semantic model, say so.
