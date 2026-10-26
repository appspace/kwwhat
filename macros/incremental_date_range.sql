{#
    Generates the body of an incremental_date_range CTE.

    Checkpoint-enabled incremental runs read the warehouse window claimed by the
    on-run-start hook. Disabled checkpoint mode, full refresh, and compile contexts use a
    deterministic range starting at start_processing_date and never read model targets.
    Both paths end the window at least(start + incremental_window, newest source row), so
    to_timestamp never runs past the data (tests/assert_outages_end_by_newest_source_row.sql).
    Unit tests set the window start with `overrides: vars: {start_processing_date: ...}` and
    mock ref('stg_ocpp_logs') with their newest timestamp, which caps the window end; lifecycle
    hooks do not run inside dbt's unit-test harness.

    Columns produced:
        from_timestamp        start of the processing window
        buffer_from_timestamp from_timestamp minus buffer_minutes
        to_timestamp          end of the bounded processing window

    Parameters:
        buffer_minutes (int): minutes to subtract for buffer_from_timestamp. Default: 0.
#}
{% macro incremental_date_range(buffer_minutes=0) %}
    {% if incremental_checkpoint_enabled() %}
        {{ incremental_checkpoint_window_sql(buffer_minutes=buffer_minutes) }}
    {% else %}
        {% set start_processing_ts = "cast('" ~ var('start_processing_date') ~ "' as " ~ dbt.type_timestamp() ~ ")" %}
        {% set window_end = timestamp_add(
            var('incremental_window').unit,
            var('incremental_window').length,
            start_processing_ts
        ) %}
        {# same end as the checkpoint claim: never past the newest source row #}
        {% set to_ts = 'least(' ~ window_end ~ ', coalesce(' ~ incremental_checkpoint_source_max_sql() ~ ', ' ~ start_processing_ts ~ '))' %}
        select
            {{ start_processing_ts }} as from_timestamp,
            {{ timestamp_add('minute', -buffer_minutes, start_processing_ts) }} as buffer_from_timestamp,
            {{ to_ts }} as to_timestamp
    {% endif %}
{% endmacro %}
