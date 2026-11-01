{#
    Generates the body of an incremental_date_range CTE.

    Normal incremental models start strictly after max(incremental_ts) in their own target and
    process at most one configured incremental_window, capped at the newest source row. Full
    refreshes and first runs start at start_processing_date.

    Sparse models can pass dense_watermark_relation. During incremental runs they use that relation's
    latest two distinct incremental_ts values as the range boundaries, so an empty sparse output
    does not stall progress. The configured incremental_window and newest source row still cap
    the upper boundary.

    Columns produced:
        from_timestamp        start of the processing window
        buffer_from_timestamp from_timestamp minus buffer_minutes
        to_timestamp          end of the processing window
#}
{% macro incremental_date_range(buffer_minutes=0, dense_watermark_relation=none) %}
    {% set start_processing_ts = "cast('" ~ var('start_processing_date') ~ "' as " ~ dbt.type_timestamp() ~ ")" %}
    {% set source_max_ts = "coalesce((select max(ingested_timestamp) from " ~ ref('stg_ocpp_logs') ~ "), " ~ start_processing_ts ~ ")" %}

    {% if is_incremental() and dense_watermark_relation is not none and execute %}
        {% set dense_to_ts = "coalesce((select max(incremental_ts) from " ~ dense_watermark_relation ~ "), " ~ start_processing_ts ~ ")" %}
        {% set from_ts = "coalesce((select max(incremental_ts) from " ~ dense_watermark_relation ~ " where incremental_ts < " ~ dense_to_ts ~ "), " ~ start_processing_ts ~ ")" %}
        {% set use_target_watermark = false %}
    {% elif flags.WHICH == 'test' %}
        {% set use_target_watermark = false %}
    {% elif is_incremental() and execute %}
        {% set target_column_names = adapter.get_columns_in_relation(this)
            | map(attribute='name') | map('lower') | list %}
        {% set target_has_incremental_ts = 'incremental_ts' in target_column_names %}
        {% set use_target_watermark = target_has_incremental_ts %}
    {% else %}
        {% set use_target_watermark = false %}
    {% endif %}

    {% if from_ts is not defined %}
        {% if use_target_watermark %}
            {% set from_ts = "coalesce((select max(incremental_ts) from " ~ this ~ "), " ~ start_processing_ts ~ ")" %}
        {% else %}
            {% set from_ts = start_processing_ts %}
        {% endif %}
    {% endif %}

    {% set window_end = timestamp_add(
        var('incremental_window').unit,
        var('incremental_window').length,
        from_ts
    ) %}
    {% if dense_to_ts is defined %}
        {% set to_ts = 'least(' ~ window_end ~ ', ' ~ dense_to_ts ~ ', ' ~ source_max_ts ~ ')' %}
    {% else %}
        {% set to_ts = 'least(' ~ window_end ~ ', ' ~ source_max_ts ~ ')' %}
    {% endif %}

    select
        {{ from_ts }} as from_timestamp,
        {{ timestamp_add('minute', -buffer_minutes, from_ts) }} as buffer_from_timestamp,
        {{ to_ts }} as to_timestamp
{% endmacro %}
