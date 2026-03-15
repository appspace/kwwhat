{#
    Generates the body of an incremental_date_range CTE.
    The caller is responsible for is_incremental() branching and passing the
    appropriate from_timestamp_caps for each path. Example:

        {%- if is_incremental() -%}
            {%- set from_ts_caps = ["(select max(incremental_ts) from " ~ this ~ ")"] -%}
        {%- else -%}
            {%- set from_ts_caps = ["cast( '" ~ var("start_processing_date") ~ "' as " ~ dbt.type_timestamp() ~ ")"] -%}
        {%- endif -%}

        with incremental_date_range as (
            {{ incremental_date_range(from_timestamp_caps=from_ts_caps, buffer_minutes=30) }}
        ),

    Columns produced:
        from_timestamp        greatest(from_timestamp_caps); start of processing window
        buffer_from_timestamp from_timestamp minus buffer_minutes; equals from_timestamp when buffer_minutes=0
        to_timestamp          least(incremental_window + from_timestamp, to_timestamp_caps)

    Parameters:
        buffer_minutes (int):       minutes to subtract for buffer_from_timestamp. Default: 0.
        from_timestamp_caps (list): SQL expressions combined with greatest() to produce from_timestamp.
        to_timestamp_caps (list):   SQL expressions applied as least() caps on to_timestamp.
#}
{% macro incremental_date_range(from_timestamp_caps, buffer_minutes=0, to_timestamp_caps=[]) %}
    {%- if from_timestamp_caps | length == 1 -%}
        {%- set from_ts_expr = from_timestamp_caps[0] -%}
    {%- else -%}
        {%- set from_ts_expr -%}
            greatest(
                {{ from_timestamp_caps | join(",\n                ") }}
            )
        {%- endset -%}
    {%- endif -%}

    {%- set base_to_ts = dbt.dateadd(var("incremental_window").unit, var("incremental_window").length, "from_timestamp") -%}

    {%- if to_timestamp_caps | length > 0 -%}
        {%- set to_ts_expr -%}
            least(
                {{ ([base_to_ts] + to_timestamp_caps) | join(",\n                ") }}
            )
        {%- endset -%}
    {%- else -%}
        {%- set to_ts_expr = base_to_ts -%}
    {%- endif -%}

    select
        from_timestamp,
        {{ dbt.dateadd("minute", -buffer_minutes, "from_timestamp") }} as buffer_from_timestamp,
        {{ to_ts_expr }} as to_timestamp
    from (
        select {{ from_ts_expr }} as from_timestamp
    )
{%- endmacro %}
