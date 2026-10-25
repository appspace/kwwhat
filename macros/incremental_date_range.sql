{#
    Generates the body of an incremental_date_range CTE.

    Checkpoint-enabled incremental runs read the warehouse window claimed by the
    on-run-start hook. Disabled checkpoint mode, full refresh, and compile contexts use a
    deterministic range starting at start_processing_date and never read model targets.
    Incremental unit tests use their mocked `this.incremental_ts` because lifecycle hooks
    do not run inside dbt's unit-test harness. Optional upstream caps coordinate dependency
    progress only in the non-checkpoint path.

    Columns produced:
        from_timestamp        start of the processing window
        buffer_from_timestamp from_timestamp minus buffer_minutes
        to_timestamp          end of the bounded processing window

    Parameters:
        buffer_minutes (int): minutes to subtract for buffer_from_timestamp. Default: 0.
        from_timestamp_caps (list): source SQL expressions that raise the non-checkpoint lower boundary.
        to_timestamp_caps (list): upstream SQL expressions that cap the non-checkpoint upper boundary.
#}
{% macro incremental_date_range(buffer_minutes=0, from_timestamp_caps=[], to_timestamp_caps=[]) %}
    {% if incremental_checkpoint_enabled() %}
        {{ incremental_checkpoint_window_sql(buffer_minutes=buffer_minutes) }}
    {% else %}
        {% set start_ts = "cast('" ~ var('start_processing_date') ~ "' as " ~ dbt.type_timestamp() ~ ")" %}
        {# resource_type, not flags.WHICH: unit tests also run under `dbt build` #}
        {% if model.resource_type == 'unit_test' and is_incremental() %}
            {% set from_ts = '(select max(incremental_ts) from ' ~ this ~ ')' %}
        {% elif from_timestamp_caps | length > 0 %}
            {% set from_ts = 'greatest(' ~ ([start_ts] + from_timestamp_caps) | join(', ') ~ ')' %}
        {% else %}
            {% set from_ts = start_ts %}
        {% endif %}
        {% set base_to_ts = timestamp_add(
            var('incremental_window').unit,
            var('incremental_window').length,
            from_ts
        ) %}
        {% if to_timestamp_caps | length > 0 %}
            {% set to_ts = 'least(' ~ ([base_to_ts] + to_timestamp_caps) | join(', ') ~ ')' %}
        {% else %}
            {% set to_ts = base_to_ts %}
        {% endif %}
        select
            {{ from_ts }} as from_timestamp,
            {{ timestamp_add('minute', -buffer_minutes, from_ts) }} as buffer_from_timestamp,
            {{ to_ts }} as to_timestamp
    {% endif %}
{% endmacro %}
