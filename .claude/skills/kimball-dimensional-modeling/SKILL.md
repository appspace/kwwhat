---
name: kimball-dimensional-modeling
description: Enforces Kimball-style dimensional modeling standards. Use when creating or reviewing fact_ or dim_ models, declaring grain, designing keys, or checking whether a model follows dimensional modeling conventions.
user-invocable: true
metadata:
  author: kwwhat
---

# Kimball Dimensional Modeling

## Additional Resources

- [Rules](references/rules.md) — Full Kimball rule set with rationale
- [Checklist](references/checklist.md) — Per-model review checklist

## When to use this skill

- Creating a new `fact_` or `dim_` model
- Reviewing an existing model for Kimball compliance
- Deciding whether a new dim should be conformed or entity-specific
- Declaring grain before writing SQL
- Choosing a key strategy

## Decision flow

```
Model requested
      ↓
1. Declare grain — if unclear, STOP and ask
      ↓
2. Classify: fact or dim?
      ↓
        fact_                          dim_
          ↓                              ↓
  3a. Keys: surrogate FKs only   3b. Keys: surrogate key + natural key
  3c. Measures: additive?        3d. Attributes only — no measures
  3d. No descriptive attrs       3e. SCD type declared?
      ↓                              ↓
4. Run checklist (references/checklist.md)
      ↓
5. Block on any blocking issue — do not proceed until resolved
```

## Step 1 — Declare grain first

Before writing any SQL:

> "One row in this model represents one **[entity]** per **[time/context]**."

If you cannot complete that sentence unambiguously, stop and ask the user. Never infer grain from column names alone.

## Step 2 — Fact or dim?

| Signal | Classification |
|--------|---------------|
| Contains measures (counts, amounts, durations) | `fact_` |
| Contains descriptive attributes about an entity | `dim_` |
| Both | split into separate models |
| Bridge or helper | document as degenerate or role-playing dim |

## Step 3a — Fact table keys

- All dimension references must use **surrogate keys** from `dim_` models
- Never join on natural keys in a fact table
- Declare a grain key with `not_null` + `unique` tests

## Step 3b — Dimension table keys

- Generate a surrogate key with `dbt_utils.generate_surrogate_key`, named `<entity>_key`
- Keep the natural key as `<entity>_natural_key`
- Surrogate key must have `not_null` + `unique` tests

## Step 3c — Measures

- Default assumption: all measures are **additive**
- If a measure is semi-additive or non-additive, document it explicitly in the column description
- If a measure appears in a `dim_` model, flag it as a blocking issue

## Step 3d / 3e — SCDs

If any dim attribute can change over time:
- Declare the SCD type (1, 2, or hybrid) in the model description
- SCD 2 requires `valid_from`, `valid_to`, `is_current` columns
- Missing SCD declaration on a mutable attribute is a **blocking issue**

## Step 4 — Run the checklist

Before finishing, walk through `references/checklist.md`. Every unchecked blocking item must be resolved.

## Step 5 — Conformed dim check

Before creating any new `dim_` model, check whether a conformed dim already exists:

```bash
find models/ -name "dim_*.sql" | xargs grep -l "<entity>"
```

If one exists, reuse it. Only create a new dim if the entity is genuinely new or the existing dim has a different grain.

## Red flags — STOP immediately

- Grain not declared before SQL is written
- `select *` anywhere in the model
- Measure column inside a `dim_` model
- Foreign key in a `fact_` model pointing to a natural key
- New `dim_` model that duplicates an existing conformed dim
- SCD attribute with no declared SCD type
- Primary key test missing

## Rationalizations to resist

| You're thinking... | Reality |
|--------------------|---------|
| "Grain is obvious from the name" | State it explicitly — reviewers and future Claude instances need it written down |
| "I'll add the SCD type later" | If the attribute can change, it must be declared now |
| "Natural keys are fine for joins" | They break when source systems change; surrogate keys are stable |
| "This measure is sort of descriptive" | Pick one. If it aggregates, it belongs in a fact. |
