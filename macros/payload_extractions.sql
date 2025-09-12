{% macro payload_extract_id_tag(action, payload, conf_payload) %}
    case 
        when {{ action }} in ('StartTransaction', 'RemoteStartTransaction') 
            then {{ fivetran_utils.json_extract(string=payload, string_path="idTag") }}
        when {{ action }} = 'Authorize'
            then {{ fivetran_utils.json_extract(string=conf_payload, string_path="idTagInfo.idTag") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_id_tag_status(action, conf_payload) %}
    case
        when {{ action }} in ('StartTransaction', 'Authorize') 
            then {{ fivetran_utils.json_extract(string=conf_payload, string_path="idTagInfo.status") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_start_ts(action, payload) %}
    case 
        when {{ action }} = 'StartTransaction'
            then {{ fivetran_utils.json_extract(string=payload, string_path="timestamp") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_stop_ts(action, payload) %}
    case 
        when {{ action }} = 'StopTransaction'
            then {{ fivetran_utils.json_extract(string=payload, string_path="timestamp") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_start(action, payload) %}
    case 
        when {{ action }} = 'StartTransaction' 
            then {{ fivetran_utils.json_extract(string=payload, string_path="meterStart") }}
        else null    
    end
{% endmacro %}

{% macro payload_extract_meter_stop(action, payload) %}
    case
        when {{ action }} = 'StopTransaction' 
            then {{ fivetran_utils.json_extract(string=payload, string_path="meterStop") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_stop_reason(action, payload) %}
    case 
        when {{ action }} = 'StopTransaction' 
            then {{ fivetran_utils.json_extract(string=payload, string_path="reason") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_transaction_id(action, payload, conf_payload) %}
    case 
        when {{ action }} in ('StopTransaction', 'RemoteStopTransaction', 'MeterValues') 
            then {{ fivetran_utils.json_extract(string=payload, string_path="transactionId") }}
        when {{ action }} = 'StartTransaction'
            then {{ fivetran_utils.json_extract(string=conf_payload, string_path="transactionId") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_meter_value(action, conf_payload) %}
    case
        when {{ action }} = 'MeterValues'
            then {{ fivetran_utils.json_extract(string=conf_payload, string_path="meterValue") }}
        else null
    end
{% endmacro %}

{% macro payload_extract_error_code(action, payload) %}
    case
        when {{ action }} = 'StatusNotification'
            then {{ fivetran_utils.json_extract(string=payload, string_path="errorCode") }}
        else null
    end
{% endmacro %}
