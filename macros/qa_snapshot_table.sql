{#
    QA-only helpers for the full-refresh vs. incremental parity check
    (see .claude/agents/quality-assurance.md). Not part of the model DAG -
    invoked manually via `dbt run-operation`.

    Snapshot names are fully qualified (database.schema.table): on DuckDB the
    schema name alone can be ambiguous, e.g. schema ANALYTICS in the catalog
    "analytics" (from analytics.duckdb), since DuckDB matches names case-insensitively.
#}

{% macro qa_snapshot_relation(model_name, suffix) %}
    {{ return(api.Relation.create(
        database=target.database,
        schema=target.schema,
        identifier=model_name ~ '_' ~ suffix
    )) }}
{% endmacro %}

{% macro qa_snapshot_model(model_name, suffix) %}
    {%- set snapshot_relation = qa_snapshot_relation(model_name, suffix) -%}
    {% set sql %}
        create or replace table {{ snapshot_relation }} as
        select * from {{ ref(model_name) }}
    {% endset %}
    {% do run_query(sql) %}
    {{ log('Snapshotted ' ~ model_name ~ ' into ' ~ snapshot_relation, info=True) }}
{% endmacro %}

{% macro qa_drop_snapshot(model_name, suffix) %}
    {%- set snapshot_relation = qa_snapshot_relation(model_name, suffix) -%}
    {% do run_query('drop table if exists ' ~ snapshot_relation) %}
    {{ log('Dropped ' ~ snapshot_relation, info=True) }}
{% endmacro %}
