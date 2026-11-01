-- Migration: rename incremental_ts to _incremental_ts on incremental model relations
--
-- Idempotent: safe to re-run. A relation is changed only when incremental_ts exists
-- and _incremental_ts does not. Relations that do not exist are skipped, and relations
-- already using _incremental_ts are left unchanged.
--
-- Run this in each dbt target database and schema before the first incremental run of
-- the code that reads _incremental_ts. Pause scheduled dbt jobs for the duration of the
-- migration so old and new code cannot run against different column names.
--
-- The migration fails if a relation contains both columns. Resolve that state manually
-- before rerunning so the authoritative watermark values are not discarded.

execute immediate $$
declare
    target_database varchar default current_database();
    target_schema varchar default current_schema();
    relation_name varchar;
    table_name varchar;
    has_old_column boolean;
    has_new_column boolean;
    renamed_count integer default 0;
    both_columns_exist exception (
        -20001,
        'Both INCREMENTAL_TS and _INCREMENTAL_TS exist. Resolve the conflicting watermark columns before rerunning.'
    );
    missing_target_schema exception (
        -20002,
        'No current database or schema is set. Set both before running this migration.'
    );
begin
    if (target_database is null or target_schema is null) then
        raise missing_target_schema;
    end if;

    for model_relation in (
        select column1::varchar as table_name
        from values
            ('FACT_CHARGE_ATTEMPTS'),
            ('FACT_DOWNTIME_DAILY'),
            ('FACT_INTERVAL_DATA'),
            ('FACT_VISITS'),
            ('INT_CONNECTOR_LATEST_STATUS'),
            ('INT_CONNECTOR_PREPARING'),
            ('INT_DRIVER_AGGREGATES'),
            ('INT_FAULTED_OUTAGES'),
            ('INT_METER_VALUES'),
            ('INT_OFFLINE_OUTAGES'),
            ('INT_STATUS_CHANGES'),
            ('INT_TRANSACTIONS')
    ) do
        table_name := model_relation.table_name;

        select
            count_if(c.column_name = 'INCREMENTAL_TS') > 0,
            count_if(c.column_name = '_INCREMENTAL_TS') > 0
        into
            :has_old_column,
            :has_new_column
        from information_schema.columns as c
        where c.table_catalog = :target_database
            and c.table_schema = :target_schema
            and c.table_name = :table_name;

        if (has_old_column and has_new_column) then
            raise both_columns_exist;
        elseif (has_old_column) then
            relation_name :=
                '"' || replace(target_database, '"', '""') || '".' ||
                '"' || replace(target_schema, '"', '""') || '".' ||
                '"' || replace(table_name, '"', '""') || '"';

            execute immediate
                'alter table ' || relation_name ||
                ' rename column "INCREMENTAL_TS" to "_INCREMENTAL_TS"';

            renamed_count := renamed_count + 1;
        end if;
    end for;

    return 'Renamed watermark columns on ' || renamed_count || ' relation(s).';
end;
$$;
