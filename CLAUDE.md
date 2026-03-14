# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**kwwhat** is a dbt project that transforms raw OCPP (Open Charge Point Protocol) 1.6 logs into EV charger reliability and utilization metrics. It models uptime, charge attempt success, and driver visit outcomes.

## Architecture

### Data flow

```
Raw OCPP logs (source)
       ↓
Staging (views)
       ↓
Intermediate (incremental)
       ↓
Marts (tables, incremental)
```

### Layer responsibilities

#### `sources`
- 1:1 mapping to raw data
- freshness + source tests
- no business logic

#### `staging`
- rename
- type cast
- basic normalization
- one model per source table
- `stg_` prefix

#### `intermediate`
- joins
- business logic
- event → entity transformations
- reusable building blocks
- `int_` prefix

#### `marts`
- business-facing models
- dimensional or wide tables
- power BI / semantic layer
- `fact_` / `dim_` prefix

#### `semantic_models`
- metrics
- entities
- measures
- dimensions
- time spine alignment

---

## Modeling Standards

### SQL style
- explicit `select` columns (never `select *`)
- trailing commas
- CTEs for readability
- meaningful CTE names

### Naming
| Type | Convention |
|------|------------|
staging | `stg_<source>__<table>`
intermediate | `int_<domain>__<purpose>`
fact | `fact_<business_process>`
dimension | `dim_<entity>`

---

## Time Handling

Always:
- use the project’s canonical timestamp
- make time grain explicit
- join to the time spine when required for metrics

---

## Keys

Every model must define:

- primary key (or declared grain)
- uniqueness test
- not null test for the grain

If grain is unclear → stop and ask.

---

## Testing Requirements

Every new model must include:

### Data tests (when relevant)
- non-negative measures
- accepted values for statuses
- business invariants
- enforcement of primary key rules from **Keys**:
  - if a model has a natural key, test it with `not_null` + `unique`
  - if a model does not have a natural key, create a surrogate key with `dbt_utils.generate_surrogate_key` and test it
  - mart models must always have a primary key test to be production-ready
- staging models are the building blocks of the project: test them thoroughly
- if a column keeps the same meaning across layers (staging → intermediate → mart), test it in staging and usually skip re-testing downstream
- marts may re-test only the most critical business fields
- columns that should never be null must have a `not_null` test (upstream providers can change constraints unexpectedly)
- columns that should be unique must have a `unique` test
- boolean columns should have an `accepted_values` test on `true` and `false`; if they should never be null, add `not_null` as well
- categorical/status/state columns should always have an `accepted_values` test
- CASE-derived categorical columns should have both `accepted_values` and `not_null` tests unless nulls are explicitly expected
- complex CASE logic should be covered by unit tests
- relationship tests can be expensive (full scans): prefer them in staging and only where referential integrity matters for downstream metrics
- on very large tables, scope tests with a `where` clause when possible to control cost, without changing the model’s behavior
- prefer `dbt_utils` tests instead of reimplementing logic:
  - `expression_is_true` to assert expressions like `net_amount + tax_amount = gross_amount`
  - `not_empty_string` to ensure strings are not empty
  - `accepted_range` to enforce numeric ranges
  - `recency` to validate data freshness
  - `not_null_proportion` when some level of nulls is acceptable

### Unit tests
- business logic
- incremental merge logic
- use custom (singular) tests for specific business rules, but prefer package tests where available
- use dict format in `expect` statements: define mock data only for the columns relevant to the test. This keeps unit tests succinct and specific.

---

## Semantic Layer Rules

When modifying semantic models:

Always ensure:
- entities have stable primary keys
- measures aggregate correctly
- dimensions match model grain
- metric definitions are time-aware

Never:
- duplicate metric logic in SQL marts
- bypass the semantic layer for metric definitions

---

## Cost Awareness

The agent must prefer:

- incremental models for large datasets
- predicate pushdown
- avoiding unnecessary reprocessing
- clustering only when justified

Before creating a full-refresh model, ask:
> Is this dataset small enough?

---

## Incremental Strategy

When creating incremental models:

Define:
- the incremental filter
- late-arriving data strategy
- unique key
- invalidation logic

---

## Documentation

Every model must include:

- description
- column-level descriptions for:
  - keys
  - business metrics
  - important flags

Write docs for **humans**, not for dbt.

---

## Anti-Patterns

The agent must NOT:

- use `select *`
- embed BI logic into staging
- calculate metrics outside the semantic layer
- create duplicate models with slightly different logic
- ignore failing tests
- run full refreshes without reason

---

## Safe Change Workflow

Before modifying existing models:

1. Read the model
2. Read its tests
3. Read its downstream dependencies
4. Check semantic model impact

After changes:

- run `dbt test` for affected nodes
- ensure tests pass

---

## When Unsure

The agent should ask for clarification if:

- grain is ambiguous
- a metric definition is unclear
- multiple modeling paths exist with different business meaning

---

## Allowed Operations

The agent can:

- create models
- refactor SQL
- add tests
- add documentation
- improve performance
- update semantic models

The agent must NOT:

- delete models without checking downstream usage
- change model grain silently
- redefine business metrics without explicit intent

---

## MCP / Agent Context

This project is designed to be consumed by:

- dbt Semantic Layer
- MCP-compatible tools
- LLM-driven analytics workflows

Therefore:

- semantic consistency > SQL convenience
- metric stability is critical

---

## Definition of Done

A task is complete only if:

- models run
- tests pass
- docs are updated
- semantic layer remains valid
- cost impact is reasonable

---

## Project Philosophy

This is a **metrics-first** project.

We model data to answer:

> What happened?  
> Why did it happen?  
> What should we do next?

Not just to produce tables.



## Common commands

```bash
# Install dependencies
dbt deps

# Load seed data (raw OCPP CSV logs and ports reference data)
dbt seed

# Run all models
dbt run

# Run all models + tests
dbt build

# Run a single model and its upstream dependencies
dbt run --select +model_name

# Run a single model (no upstream)
dbt run --select model_name

# Full refresh of all incremental models (re-processes from start_processing_date)
dbt run --full-refresh

# Run all tests
dbt test

# Run tests for a single model
dbt test --select model_name

# Run only unit tests
dbt test --select "test_type:unit"

# Compile without running (useful for debugging SQL)
dbt compile --select model_name
```