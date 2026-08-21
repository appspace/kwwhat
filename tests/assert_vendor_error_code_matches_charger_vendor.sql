-- For every non-null dim_connectors.latest_vendor_error_code, a dim_error_codes row must
-- exist matching both that connector's charger's charge_point_vendor (via dim_chargers) and
-- the fault code. This is the composite (vendor, fault_code) check that the built-in
-- relationships test on fault_code alone cannot express.

with connectors_with_vendor_codes as (
    select
        dim_connectors.charger_id,
        dim_connectors.connector_id,
        dim_connectors.latest_vendor_error_code,
        dim_chargers.charge_point_vendor
    from {{ ref('dim_connectors') }}
    inner join {{ ref('dim_chargers') }}
        on dim_connectors.charger_id = dim_chargers.charger_id
    where dim_connectors.latest_vendor_error_code is not null
)

select
    connectors_with_vendor_codes.charger_id,
    connectors_with_vendor_codes.connector_id,
    connectors_with_vendor_codes.latest_vendor_error_code,
    connectors_with_vendor_codes.charge_point_vendor
from connectors_with_vendor_codes
left join {{ ref('dim_error_codes') }}
    on connectors_with_vendor_codes.charge_point_vendor = dim_error_codes.vendor
    and connectors_with_vendor_codes.latest_vendor_error_code = dim_error_codes.fault_code
where dim_error_codes.error_code_key is null
