{{
  config(
    materialized='view'
  )
}}

with source as (
    select * from {{ source('raw', 'ocpp_logs') }}
),

renamed as (
    select
        -- Convert timestamp to proper timestamp type using dbt macro for cross-platform compatibility
        cast(timestamp as {{ dbt.type_timestamp() }}) as ingested_timestamp,
        
        -- Charge point identifier
        cast(id as {{ dbt.type_string() }}) as charge_point_id,
        
        -- OCPP action type (can be null for response messages)
        cast(action as {{ dbt.type_string() }}) as action,
                
        -- Extract MessageTypeId from the JSON array for easier filtering
        -- Using fivetran_utils json_extract macro
        cast({{ fivetran_utils.json_extract(string="msg", string_path=[0]) }} as {{ dbt.type_string() }}) as message_type_id,
        
        -- Extract MessageId from the JSON array
        cast({{ fivetran_utils.json_extract(string="msg", string_path=[1]) }} as {{ dbt.type_string() }}) as unique_id,
        
        -- Extract Payload from the JSON array
        case 
            when {{ fivetran_utils.json_extract(string="msg", string_path=[0]) }} = '2' 
            then {{ fivetran_utils.json_extract(string="msg", string_path=[3]) }}
            when {{ fivetran_utils.json_extract(string="msg", string_path=[0]) }} = '3' 
            then {{ fivetran_utils.json_extract(string="msg", string_path=[2]) }}
            else null
        end as payload

    from source
)

select * from renamed
