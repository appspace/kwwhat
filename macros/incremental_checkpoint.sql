{% macro incremental_checkpoint_enabled() %}
    {{ return(
        var('incremental_checkpoint_enabled', false)
        and not flags.FULL_REFRESH
        and flags.WHICH in ['run', 'build']
    ) }}
{% endmacro %}

{% macro incremental_checkpoint_name() %}
    {{ return(project_name ~ ':' ~ var('incremental_checkpoint_name', 'ocpp_incremental_pipeline')) }}

{% endmacro %}

{% macro incremental_checkpoint_relation() %}
    {{ return(api.Relation.create(
        database=target.database,
        schema=target.schema,
        identifier=var('incremental_checkpoint_identifier', '_kwwhat_incremental_checkpoint')
    )) }}
{% endmacro %}

{% macro incremental_checkpoint_string(value) %}
    {{ return("'" ~ (value | string | replace("'", "''")) ~ "'") }}
{% endmacro %}

{% macro ensure_incremental_checkpoint_relation() %}
    {% set checkpoint_relation = incremental_checkpoint_relation() %}
    {% set create_sql %}
        create table if not exists {{ checkpoint_relation }} (
            checkpoint_name {{ dbt.type_string() }} not null,
            target_name {{ dbt.type_string() }} not null,
            status {{ dbt.type_string() }} not null,
            completed_through_ts {{ dbt.type_timestamp() }} not null,
            pending_from_ts {{ dbt.type_timestamp() }},
            pending_to_ts {{ dbt.type_timestamp() }},
            claim_id {{ dbt.type_string() }},
            claimed_at {{ dbt.type_timestamp() }},
            lease_expires_at {{ dbt.type_timestamp() }},
            updated_at {{ dbt.type_timestamp() }} not null
        )
    {% endset %}
    {% do run_query(create_sql) %}
    {{ return(checkpoint_relation) }}
{% endmacro %}

{% macro incremental_checkpoint_source_max_sql() %}
    {{ return('(select max(ingested_timestamp) from ' ~ ref('stg_ocpp_logs') ~ ')') }}
{% endmacro %}

{% macro claim_incremental_checkpoint() %}
    {% if not execute or not incremental_checkpoint_enabled() %}
        {{ return('select 1') }}
    {% endif %}

    {% set checkpoint_relation = ensure_incremental_checkpoint_relation() %}
    {% set checkpoint_name = incremental_checkpoint_string(incremental_checkpoint_name()) %}
    {% set target_name = incremental_checkpoint_string(target.name) %}
    {% set claim_id = incremental_checkpoint_string(invocation_id) %}
    {% set start_ts = "cast(" ~ incremental_checkpoint_string(var('start_processing_date')) ~ " as " ~ dbt.type_timestamp() ~ ")" %}
    {% set source_max = "coalesce(" ~ incremental_checkpoint_source_max_sql() ~ ", " ~ start_ts ~ ")" %}
    {% set lease_expires = timestamp_add('minute', var('incremental_checkpoint_lease_minutes', 120), 'current_timestamp') %}

    {% set claim_sql %}
        merge into {{ checkpoint_relation }} as t
        using (
            select
                {{ checkpoint_name }} as checkpoint_name,
                {{ target_name }} as target_name,
                {{ claim_id }} as claim_id,
                {{ start_ts }} as start_ts,
                {{ source_max }} as source_max_ts
        ) as s
            on t.checkpoint_name = s.checkpoint_name
            and t.target_name = s.target_name
        when matched and t.status = 'completed' then update set
            status = 'pending',
            pending_from_ts = t.completed_through_ts,
            pending_to_ts = least(
                {{ timestamp_add(
                    var('incremental_window').unit,
                    var('incremental_window').length,
                    't.completed_through_ts'
                ) }},
                s.source_max_ts
            ),
            claim_id = s.claim_id,
            claimed_at = current_timestamp,
            lease_expires_at = {{ lease_expires }},
            updated_at = current_timestamp
        when matched
            and t.status = 'pending'
            and t.lease_expires_at < current_timestamp
        then update set
            claim_id = s.claim_id,
            claimed_at = current_timestamp,
            lease_expires_at = {{ lease_expires }},
            updated_at = current_timestamp
        when not matched then insert (
            checkpoint_name,
            target_name,
            status,
            completed_through_ts,
            pending_from_ts,
            pending_to_ts,
            claim_id,
            claimed_at,
            lease_expires_at,
            updated_at
        ) values (
            s.checkpoint_name,
            s.target_name,
            'pending',
            s.start_ts,
            s.start_ts,
            least(
                {{ timestamp_add(
                    var('incremental_window').unit,
                    var('incremental_window').length,
                    's.start_ts'
                ) }},
                s.source_max_ts
            ),
            s.claim_id,
            current_timestamp,
            {{ lease_expires }},
            current_timestamp
        )
    {% endset %}
    {% do run_query(claim_sql) %}

    {% set ownership_sql %}
        select claim_id
        from {{ checkpoint_relation }}
        where checkpoint_name = {{ checkpoint_name }}
            and target_name = {{ target_name }}
            and status = 'pending'
    {% endset %}
    {% set ownership = run_query(ownership_sql) %}
    {% if ownership | length == 0 or ownership.rows[0][0] != invocation_id %}
        {{ exceptions.raise_compiler_error(
            'Incremental checkpoint is already claimed by another active invocation. '
            ~ 'Wait for its lease to expire or inspect it with show_incremental_checkpoint.'
        ) }}
    {% endif %}

    {{ log('Claimed incremental window for ' ~ incremental_checkpoint_name() ~ ' with invocation ' ~ invocation_id, info=True) }}
    {{ return('select 1') }}
{% endmacro %}

{% macro incremental_checkpoint_window_sql(buffer_minutes=0) %}
    {% set checkpoint_relation = incremental_checkpoint_relation() %}
    {% set checkpoint_name = incremental_checkpoint_string(incremental_checkpoint_name()) %}
    {% set target_name = incremental_checkpoint_string(target.name) %}
    {% set claim_id = incremental_checkpoint_string(invocation_id) %}

    select
        pending_from_ts as from_timestamp,
        {{ timestamp_add('minute', -buffer_minutes, 'pending_from_ts') }} as buffer_from_timestamp,
        pending_to_ts as to_timestamp
    from {{ checkpoint_relation }}
    where checkpoint_name = {{ checkpoint_name }}
        and target_name = {{ target_name }}
        and status = 'pending'
        and claim_id = {{ claim_id }}
{% endmacro %}

{% macro finalize_incremental_checkpoint(results) %}
    {% if not execute or not incremental_checkpoint_enabled() %}
        {{ return('select 1') }}
    {% endif %}

    {% set failed_results = [] %}
    {% for result in results %}
        {% set result_status = result.status | string | lower %}
        {% if result_status in ['error', 'fail', 'runtime error'] %}
            {% do failed_results.append(result.node.unique_id) %}
        {% endif %}
    {% endfor %}

    {% if failed_results | length > 0 %}
        {{ log(
            'Leaving incremental checkpoint pending because resources failed: '
            ~ (failed_results | join(', ')),
            info=True
        ) }}
        {{ return('select 1') }}
    {% endif %}

    {% set checkpoint_relation = incremental_checkpoint_relation() %}
    {% set checkpoint_name = incremental_checkpoint_string(incremental_checkpoint_name()) %}
    {% set target_name = incremental_checkpoint_string(target.name) %}
    {% set claim_id = incremental_checkpoint_string(invocation_id) %}
    {% set finalize_sql %}
        update {{ checkpoint_relation }}
        set
            status = 'completed',
            completed_through_ts = pending_to_ts,
            pending_from_ts = null,
            pending_to_ts = null,
            claim_id = null,
            claimed_at = null,
            lease_expires_at = null,
            updated_at = current_timestamp
        where checkpoint_name = {{ checkpoint_name }}
            and target_name = {{ target_name }}
            and status = 'pending'
            and claim_id = {{ claim_id }}
    {% endset %}
    {% do run_query(finalize_sql) %}
    {{ log('Finalized incremental checkpoint for ' ~ incremental_checkpoint_name(), info=True) }}
    {{ return('select 1') }}
{% endmacro %}

{% macro initialize_incremental_checkpoint(completed_through_ts, checkpoint_name=none) %}
    {% set checkpoint_relation = ensure_incremental_checkpoint_relation() %}
    {% set selected_name = checkpoint_name if checkpoint_name is not none else incremental_checkpoint_name() %}
    {% set checkpoint_name_sql = incremental_checkpoint_string(selected_name) %}
    {% set target_name_sql = incremental_checkpoint_string(target.name) %}
    {% set completed_ts_sql = "cast(" ~ incremental_checkpoint_string(completed_through_ts) ~ " as " ~ dbt.type_timestamp() ~ ")" %}

    {% do run_query(
        'delete from ' ~ checkpoint_relation
        ~ ' where checkpoint_name = ' ~ checkpoint_name_sql
        ~ ' and target_name = ' ~ target_name_sql
    ) %}
    {% set insert_sql %}
        insert into {{ checkpoint_relation }} (
            checkpoint_name,
            target_name,
            status,
            completed_through_ts,
            updated_at
        ) values (
            {{ checkpoint_name_sql }},
            {{ target_name_sql }},
            'completed',
            {{ completed_ts_sql }},
            current_timestamp
        )
    {% endset %}
    {% do run_query(insert_sql) %}
    {{ log('Initialized checkpoint ' ~ selected_name ~ ' at ' ~ completed_through_ts, info=True) }}
{% endmacro %}

{% macro show_incremental_checkpoint(checkpoint_name=none) %}
    {% set checkpoint_relation = ensure_incremental_checkpoint_relation() %}
    {% set selected_name = checkpoint_name if checkpoint_name is not none else incremental_checkpoint_name() %}
    {% set query %}
        select *
        from {{ checkpoint_relation }}
        where checkpoint_name = {{ incremental_checkpoint_string(selected_name) }}
            and target_name = {{ incremental_checkpoint_string(target.name) }}
    {% endset %}
    {% set checkpoint = run_query(query) %}
    {% if execute %}
        {% do checkpoint.print_table() %}
    {% endif %}

{% endmacro %}


{% macro reset_incremental_checkpoint(checkpoint_name=none) %}
    {% set checkpoint_relation = ensure_incremental_checkpoint_relation() %}
    {% set selected_name = checkpoint_name if checkpoint_name is not none else incremental_checkpoint_name() %}
    {% set reset_sql %}
        delete from {{ checkpoint_relation }}
        where checkpoint_name = {{ incremental_checkpoint_string(selected_name) }}
            and target_name = {{ incremental_checkpoint_string(target.name) }}
    {% endset %}
    {% do run_query(reset_sql) %}
    {{ log('Reset checkpoint ' ~ selected_name, info=True) }}
{% endmacro %}
