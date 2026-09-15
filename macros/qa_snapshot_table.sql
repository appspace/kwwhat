{#
    QA-only helpers for the full-refresh vs. incremental parity check
    (see .claude/agents/quality-assurance.md). Not part of the model DAG -
    invoked manually via `dbt run-operation`.
#}

{% macro qa_snapshot_model(model_name, suffix) %}
    {%- set snapshot_relation = target.schema ~ '.' ~ model_name ~ '_' ~ suffix -%}
    {% set sql %}
        create or replace table {{ snapshot_relation }} as
        select * from {{ ref(model_name) }}
    {% endset %}
    {% do run_query(sql) %}
    {{ log('Snapshotted ' ~ model_name ~ ' into ' ~ snapshot_relation, info=True) }}
{% endmacro %}

{% macro qa_drop_snapshot(model_name, suffix) %}
    {%- set snapshot_relation = target.schema ~ '.' ~ model_name ~ '_' ~ suffix -%}
    {% do run_query('drop table if exists ' ~ snapshot_relation) %}
    {{ log('Dropped ' ~ snapshot_relation, info=True) }}
{% endmacro %}
