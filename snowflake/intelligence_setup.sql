-- Summary of objects created in this script:
--
-- Roles:
--   - intelligence_admin
--
-- Warehouses:
--   - intelligence_wh
--
-- Databases:
--   - analytics
--   - snowflake_intelligence
--
-- Schemas:
--   - analytics.dbt_prod
--   - snowflake_intelligence.agents
--
-- Stages:
--   - semantic_models
--

use role accountadmin;

create or replace role intelligence_admin;
grant create warehouse on account to role intelligence_admin;
grant create database on account to role intelligence_admin;
grant create integration on account to role intelligence_admin;

set current_user = (select current_user());   
grant role intelligence_admin to user identifier($current_user);

alter user set default_role = intelligence_admin;
alter user set default_warehouse = intelligence_wh;

use role intelligence_admin;
create or replace warehouse intelligence_wh
    warehouse_size = xsmall
    auto_suspend = 60
    auto_resume = true
    initially_suspended = true;

grant all on warehouse intelligence_wh to role intelligence_admin;    

create database if not exists snowflake_intelligence;
create schema if not exists snowflake_intelligence.agents;

grant create agent on schema snowflake_intelligence.agents to role intelligence_admin;

use database analytics;
use schema dbt_prod;
use warehouse intelligence_wh;

GRANT CREATE STAGE ON SCHEMA analytics.DBT_PROD TO ROLE intelligence_admin;
create or replace stage semantic_models encryption = (type = 'snowflake_sse') directory = ( enable = true );

ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'AWS_US';

select 'Congratulations! Snowflake Intelligence setup has completed successfully!' as status;
