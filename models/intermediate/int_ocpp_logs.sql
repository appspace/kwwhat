{{
  config(
    materialized='view'
  )
}}

with logs as (
    select
        ingested_timestamp,
        charger_id,
        action,
        message_type_id,
        unique_id,
        payload,
        -- OCPP connectorId is numbered per charger; scope it so connector_id matches int_connectors ('CH-002-3')
        {{ network_scoped_id('charger_id', payload_extract_connector_id('action', 'payload')) }} as connector_id
    from {{ ref('stg_ocpp_logs') }}
),

-- charger_id + connector_id -> port_id (int_connectors); charger_id -> location_id (int_chargers)
logs_with_ids as (
    select
        logs.ingested_timestamp,
        logs.charger_id,
        logs.action,
        logs.message_type_id,
        logs.unique_id,
        logs.payload,
        logs.connector_id,
        connectors.port_id,
        chargers.location_id
    from logs
    left join {{ ref('int_connectors') }} as connectors
        on logs.charger_id = connectors.charger_id
        and logs.connector_id = connectors.connector_id
    left join {{ ref('int_chargers') }} as chargers
        on logs.charger_id = chargers.charger_id
)

select
    ingested_timestamp,
    charger_id,
    connector_id,
    port_id,
    location_id,
    action,
    message_type_id,
    unique_id,
    payload
from logs_with_ids