-- Fixture data for fact_charge_attempts unit test
-- Two authorized attempts 15 minutes apart on the same charger with the same idTag
-- This fixture provides mock data that replaces fact_charge_attempts output
-- Includes all columns that fact_charge_attempts outputs
-- Note: Dates must be after start_processing_date (2025-10-01) to pass the date filter
select 
    md5('CH-001' || '1' || '2025-10-02 10:00:00') as charge_attempt_id,  -- Generated surrogate key
    'CH-001' as charge_point_id,
    '1' as connector_id,
    cast('2025-10-02 10:00:00' as timestamp) as ingested_ts,
    cast(null as timestamp) as charge_attempt_ingested_ts,
    cast(null as string) as previous_status,
    cast(null as string) as status,
    cast(null as string) as next_status,
    ['TAG-001'] as id_tags,
    ['Accepted'] as id_tag_statuses,
    'TXN-001' as transaction_id,
    cast(null as timestamp) as transaction_start_ts,
    cast(null as timestamp) as transaction_stop_ts,
    cast(null as timestamp) as transaction_ingested_ts,
    cast(null as string) as transaction_stop_reason,
    cast(null as numeric) as meter_start_wh,
    cast(null as numeric) as meter_stop_wh,
    5.5 as energy_transferred_kwh,
    cast(null as array) as error_codes,
    true as is_successful,
    cast('2025-10-02 10:20:00' as timestamp) as incremental_ts
union all
select 
    md5('CH-001' || '1' || '2025-10-02 10:15:00') as charge_attempt_id,  -- Generated surrogate key
    'CH-001' as charge_point_id,
    1 as connector_id,
    cast('2025-10-02 10:15:00' as timestamp) as ingested_ts,  -- 15 minutes later
    cast(null as timestamp) as charge_attempt_ingested_ts,
    cast(null as string) as previous_status,
    cast(null as string) as status,
    cast(null as string) as next_status,
    ['TAG-001'] as id_tags,  -- Same idTag
    ['Accepted'] as id_tag_statuses,
    'TXN-002' as transaction_id,
    cast(null as timestamp) as transaction_start_ts,
    cast(null as timestamp) as transaction_stop_ts,
    cast(null as timestamp) as transaction_ingested_ts,
    cast(null as string) as transaction_stop_reason,
    cast(null as numeric) as meter_start_wh,
    cast(null as numeric) as meter_stop_wh,
    6.2 as energy_transferred_kwh,
    cast(null as array) as error_codes,
    true as is_successful,
    cast('2025-10-02 10:20:00' as timestamp) as incremental_ts

