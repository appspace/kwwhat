# Kimball Model Review Checklist

Run through this checklist before signing off any `fact_` or `dim_` model.

## For all models

- [ ] Grain is declared in the model description
- [ ] Primary key exists and has `not_null` + `unique` tests
- [ ] Model description is written for humans, not dbt
- [ ] Column descriptions exist for all keys and measures

## For `dim_` models

- [ ] Surrogate key present, named `<entity>_key`, generated with `dbt_utils.generate_surrogate_key`
- [ ] Natural key retained as `<entity>_natural_key`
- [ ] No measures in the model
- [ ] SCD type declared if any attribute can change over time
- [ ] Confirmed no duplicate conformed dim already exists

## For `fact_` models

- [ ] All dimension references use surrogate keys (not natural keys)
- [ ] All measures are additive, or semi/non-additive status is documented
- [ ] No descriptive attributes — those belong in dims
- [ ] Grain is one row per declared grain, no fan-out
- [ ] Degenerate dimensions (if any) are documented

## Blocking issues (must fix before merging)

- Grain not declared
- Surrogate key missing from a dim
- Measure in a dim table
- Natural key used as FK in a fact table
- SCD attribute with no declared SCD type
- Duplicate dim logic that should be a conformed dim
