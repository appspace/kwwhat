{#
    Generates the body of an incremental_date_range CTE from model-local output state.

    Normal incremental models start strictly after max(incremental_ts) in their own target and
    process at most one configured incremental_window, capped at the newest source row. Full
    refreshes and first runs start at start_processing_date.

    Sparse outage models pass uncapped=true. They read from their last output watermark through
    the newest source row so an outage-free period cannot strand them behind an empty window.

    Columns produced:
        from_timestamp        start of the processing window
        buffer_from_timestamp from_timestamp minus buffer_minutes
        to_timestamp          end of the processing window
#}
{% macro incremental_date_range(buffer_minutes=0, uncapped=false) %}
    {% set start_processing_ts = "cast('" ~ var('start_processing_date') ~ "' as " ~ dbt.type_timestamp() ~ ")" %}
    {% set source_max_ts = "coalesce((select max(ingested_timestamp) from " ~ ref('stg_ocpp_logs') ~ "), " ~ start_processing_ts ~ ")" %}

    {% if flags.WHICH == 'test' %}
        {% set target_has_incremental_ts = var('unit_test_model_watermark_enabled', false) %}
    {% elif is_incremental() and execute %}
        {% set target_column_names = adapter.get_columns_in_relation(this)
            | map(attribute='name') | map('lower') | list %}
        {% set target_has_incremental_ts = 'incremental_ts' in target_column_names %}
    {% else %}
        {% set target_has_incremental_ts = false %}
    {% endif %}

    {% set use_target_watermark = is_incremental() and target_has_incremental_ts %}
    {% if use_target_watermark %}
        {% set from_ts = "coalesce((select max(incremental_ts) from " ~ this ~ "), " ~ start_processing_ts ~ ")" %}
    {% else %}
        {% set from_ts = start_processing_ts %}
    {% endif %}

    {% if uncapped and use_target_watermark %}
        {% set to_ts = source_max_ts %}
    {% else %}
        {% set window_end = timestamp_add(
            var('incremental_window').unit,
            var('incremental_window').length,
            from_ts
        ) %}
        {% set to_ts = 'least(' ~ window_end ~ ', ' ~ source_max_ts ~ ')' %}
    {% endif %}

    select
        {{ from_ts }} as from_timestamp,
        {{ timestamp_add('minute', -buffer_minutes, from_ts) }} as buffer_from_timestamp,
        {{ to_ts }} as to_timestamp
{% endmacro %}
