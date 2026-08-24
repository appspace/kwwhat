{% macro payload_extract_id_tag(action, payload, conf_payload) %}
    case 
        when {{ action }} in ('StartTransaction', 'RemoteStartTransaction') 
            then cast({{ json_extract(string=payload, string_path="idTag") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_parent_id_tag(action, payload, conf_payload) %}
    case 
        when {{ action }} = 'Authorize'
            then cast({{ json_extract(string=conf_payload, string_path="idTagInfo.idTag") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_id_tag_status(action, conf_payload) %}
    case
        when {{ action }} in ('StartTransaction', 'Authorize') 
            then cast({{ json_extract(string=conf_payload, string_path="idTagInfo.status") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_start_ts(action, payload) %}
    case 
        when {{ action }} = 'StartTransaction'
            then cast({{ json_extract(string=payload, string_path="timestamp") }} as {{ dbt.type_timestamp() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_stop_ts(action, payload) %}
    case 
        when {{ action }} = 'StopTransaction'
            then cast({{ json_extract(string=payload, string_path="timestamp") }} as {{ dbt.type_timestamp() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_start(action, payload) %}
    case 
        when {{ action }} = 'StartTransaction' 
            then cast({{ json_extract(string=payload, string_path="meterStart") }} as {{ dbt.type_numeric() }})
        else null    
    end
{% endmacro %}

{% macro payload_extract_meter_stop(action, payload) %}
    case
        when {{ action }} = 'StopTransaction' 
            then cast({{ json_extract(string=payload, string_path="meterStop") }} as {{ dbt.type_numeric() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_stop_reason(action, payload) %}
    case 
        when {{ action }} = 'StopTransaction'
            -- If a transaction is ended in a normal way (e.g. EV-driver presented his identification to stop the transaction), the
            -- Reason element MAY be omitted and the Reason SHOULD be assumed 'Local'.
            then coalesce(cast({{ json_extract(string=payload, string_path="reason") }} as {{ dbt.type_string() }}), 'Local')
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_id(action, payload, conf_payload) %}
    case 
        when {{ action }} in ('StopTransaction', 'RemoteStopTransaction', 'MeterValues') 
            then cast({{ json_extract(string=payload, string_path="transactionId") }} as {{ dbt.type_string() }})
        when {{ action }} = 'StartTransaction'
            then cast({{ json_extract(string=conf_payload, string_path="transactionId") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_value(action, conf_payload) %}
    case
        when {{ action }} = 'MeterValues'
            then cast({{ json_extract(string=conf_payload, string_path="meterValue") }} as {{ dbt.type_numeric() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_error_code(action, payload) %}
    case
        when {{ action }} = 'StatusNotification'
            then cast({{ json_extract(string=payload, string_path="errorCode") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_vendor_error_code(action, payload) %}
    -- Vendor-specific fault code (e.g. ChargeX MREC 'CX001', see https://chargex.inl.gov). Meaning is
    -- scheme-dependent - decode via dim_error_codes scoped to the reporting connector's vendor_id
    -- (payload_extract_vendor_id), not the charger's OEM/manufacturer.
    case
        when {{ action }} = 'StatusNotification'
            then cast({{ json_extract(string=payload, string_path="vendorErrorCode") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_vendor_id(action, payload) %}
    -- Identifies the vendor-specific fault-code scheme that vendorErrorCode belongs to (e.g.
    -- ChargeX's 'https://chargex.inl.gov', see the ChargeX Implementation Guide for Minimum
    -- Required Error Codes). This is not the charger's OEM/manufacturer - it names the taxonomy
    -- used to interpret vendorErrorCode, and is what scopes the (vendor, fault_code) lookup in
    -- dim_error_codes.
    case
        when {{ action }} = 'StatusNotification'
            then cast({{ json_extract(string=payload, string_path="vendorId") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_info(action, payload) %}
    -- Additional detail accompanying errorCode/vendorErrorCode - the actual or observed value
    -- (e.g. '50' for a HighTemperature reading in degrees Celsius). Optional, may be blank.
    case
        when {{ action }} = 'StatusNotification'
            then cast({{ json_extract(string=payload, string_path="info") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_connector_id(action, payload) %}
    case 
        when {{ action }} in ('StatusNotification', 'StartTransaction', 'MeterValues', 'RemoteStartTransaction')
            then cast({{ json_extract(string=payload, string_path="connectorId") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_status(action, payload) %}
    case 
        when {{ action }} = 'StatusNotification'
            then cast({{ json_extract(string=payload, string_path="status") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_timestamp(action, payload) %}
    case 
        when {{ action }} in ('StatusNotification', 'StartTransaction', 'StopTransaction')
            then cast({{ json_extract(string=payload, string_path="timestamp") }} as {{ dbt.type_timestamp() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_values(action, payload) %}
    case
        when {{ action }} = 'MeterValues'
            then {{ adapter.dispatch('meter_values_json', 'kwwhat')(payload) }}
        else null
    end
{% endmacro %}

{% macro default__meter_values_json(payload) %}cast(json_extract(try_parse_json({{ payload }}), '$.meterValue') as array(json)){% endmacro %}
{% macro snowflake__meter_values_json(payload) %}try_parse_json({{ payload }}):meterValue{% endmacro %}
{% macro bigquery__meter_values_json(payload) %}json_extract_array({{ payload }}, '$.meterValue'){% endmacro %}
{% macro duckdb__meter_values_json(payload) %}json_extract({{ payload }}, '$.meterValue'){% endmacro %}
{% macro postgres__meter_values_json(payload) %}({{ payload }}::jsonb -> 'meterValue'){% endmacro %}
{% macro redshift__meter_values_json(payload) %}({{ payload }}::jsonb -> 'meterValue'){% endmacro %}
{% macro spark__meter_values_json(payload) %}from_json({{ payload }}, 'STRUCT<meterValue: ARRAY<STRUCT<timestamp: STRING, sampledValue: ARRAY<STRUCT<measurand: STRING, value: STRING, unit: STRING, phase: STRING>>>>>').meterValue{% endmacro %}
{% macro databricks__meter_values_json(payload) %}from_json({{ payload }}, 'STRUCT<meterValue: ARRAY<STRUCT<timestamp: STRING, sampledValue: ARRAY<STRUCT<measurand: STRING, value: STRING, unit: STRING, phase: STRING>>>>>').meterValue{% endmacro %}
