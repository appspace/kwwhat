-- fact_downtime_daily.error_codes is documented as decodable via dim_error_codes scoped
-- to taxonomy = 'ocpp1.6'. Unlike vendor_error_codes (which needs a paired taxonomy per
-- code), error_codes has no ambiguity - it's always that one taxonomy - so this checks
-- the claim holds: every code in the array actually exists there.

with unnested as (
    select
        f.downtime_id,
        cast(ec.value as {{ dbt.type_string() }}) as error_code
    from {{ ref('fact_downtime_daily') }} as f
    {{ array_unnest('f.error_codes') }} as ec
    where f.error_codes is not null
)

select
    unnested.downtime_id,
    unnested.error_code
from unnested
left join {{ ref('dim_error_codes') }} as dim_error_codes
    on unnested.error_code = dim_error_codes.fault_code
    and dim_error_codes.taxonomy = 'ocpp1.6'
where dim_error_codes.error_code_key is null
