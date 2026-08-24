-- For every non-null dim_connectors.latest_vendor_error_code, a dim_error_codes row must
-- exist matching both that connector's latest_vendor_id (the fault-code scheme reported
-- alongside vendorErrorCode on the same StatusNotification, e.g. ChargeX's
-- 'https://chargex.inl.gov') and the fault code. This is the composite (vendor, fault_code)
-- check that the built-in relationships test on fault_code alone cannot express.

with connectors_with_vendor_codes as (
    select
        charger_id,
        connector_id,
        latest_vendor_error_code,
        latest_vendor_id
    from {{ ref('dim_connectors') }}
    where latest_vendor_error_code is not null
)

select
    connectors_with_vendor_codes.charger_id,
    connectors_with_vendor_codes.connector_id,
    connectors_with_vendor_codes.latest_vendor_error_code,
    connectors_with_vendor_codes.latest_vendor_id
from connectors_with_vendor_codes
left join {{ ref('dim_error_codes') }}
    on connectors_with_vendor_codes.latest_vendor_id = dim_error_codes.vendor
    and connectors_with_vendor_codes.latest_vendor_error_code = dim_error_codes.fault_code
where dim_error_codes.error_code_key is null
