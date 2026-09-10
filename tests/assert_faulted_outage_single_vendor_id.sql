select
    charger_id,
    port_id,
    from_ts,
    vendor_ids
from {{ ref('int_faulted_outages') }}
where {{ array_size('vendor_ids') }} > 1
