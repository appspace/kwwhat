{% macro payload_extract_id_tag(action, payload, conf_payload) %}
    case 
        when {{ action }} in ('StartTransaction', 'RemoteStartTransaction') 
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="idTag") }} as {{ dbt.type_string() }})
        when {{ action }} = 'Authorize'
            then cast({{ fivetran_utils.json_extract(string=conf_payload, string_path="idTagInfo.idTag") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_id_tag_status(action, conf_payload) %}
    case
        when {{ action }} in ('StartTransaction', 'Authorize') 
            then cast({{ fivetran_utils.json_extract(string=conf_payload, string_path="idTagInfo.status") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_start_ts(action, payload) %}
    case 
        when {{ action }} = 'StartTransaction'
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="timestamp") }} as {{ dbt.type_timestamp() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_stop_ts(action, payload) %}
    case 
        when {{ action }} = 'StopTransaction'
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="timestamp") }} as {{ dbt.type_timestamp() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_start(action, payload) %}
    case 
        when {{ action }} = 'StartTransaction' 
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="meterStart") }} as {{ dbt.type_numeric() }})
        else null    
    end
{% endmacro %}

{% macro payload_extract_meter_stop(action, payload) %}
    case
        when {{ action }} = 'StopTransaction' 
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="meterStop") }} as {{ dbt.type_numeric() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_stop_reason(action, payload) %}
    case 
        when {{ action }} = 'StopTransaction'
            -- If a transaction is ended in a normal way (e.g. EV-driver presented his identification to stop the transaction), the
            -- Reason element MAY be omitted and the Reason SHOULD be assumed 'Local'.
            then coalesce(cast({{ fivetran_utils.json_extract(string=payload, string_path="reason") }} as {{ dbt.type_string() }}), 'Local')
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_id(action, payload, conf_payload) %}
    case 
        when {{ action }} in ('StopTransaction', 'RemoteStopTransaction', 'MeterValues') 
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="transactionId") }} as {{ dbt.type_string() }})
        when {{ action }} = 'StartTransaction'
            then cast({{ fivetran_utils.json_extract(string=conf_payload, string_path="transactionId") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_value(action, conf_payload) %}
    case
        when {{ action }} = 'MeterValues'
            then cast({{ fivetran_utils.json_extract(string=conf_payload, string_path="meterValue") }} as {{ dbt.type_numeric() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_error_code(action, payload) %}
    case
        when {{ action }} = 'StatusNotification'
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="errorCode") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_connector_id(action, payload) %}
    case 
        when {{ action }} in ('StatusNotification', 'StartTransaction', 'MeterValues', 'RemoteStartTransaction')
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="connectorId") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_status(action, payload) %}
    case 
        when {{ action }} = 'StatusNotification'
            then cast({{ fivetran_utils.json_extract(string=payload, string_path="status") }} as {{ dbt.type_string() }})
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_values(action, payload) %}
    case
        when {{ action }} = 'MeterValues'
            then
                {% if target.type == 'snowflake' %}
                    try_parse_json({{ payload }}):meterValue
                {% elif target.type == 'bigquery' %}
                    json_extract_array({{ payload }}, '$.meterValue')
                {% elif target.type in ['trino', 'presto', 'athena'] %}
                    cast(json_extract(try_parse_json({{ payload }}), '$.meterValue') as array(json))
                {% elif target.type in ['postgres', 'redshift', 'duckdb'] %}
                    ({{ payload }}::jsonb -> 'meterValue')
                {% elif target.type in ['spark', 'databricks'] %}
                    from_json({{ payload }}, 'STRUCT<meterValue: ARRAY<STRUCT<timestamp: STRING, sampledValue: ARRAY<STRUCT<measurand: STRING, value: STRING, unit: STRING, phase: STRING>>>>>').meterValue
                {% else %}
                    cast(json_extract(try_parse_json({{ payload }}), '$.meterValue') as array(json))
                {% endif %}
        else null
    end
{% endmacro %}
