# Kimball Dimensional Modeling Rules

## 1. Grain-first design

Every model must declare its grain before any SQL is written.

- Grain = one row represents exactly one **[thing]** per **[time/context]**
- If the grain is ambiguous, stop and ask. Never guess.
- Example: `fact_charge_attempts` — one row per charge attempt per port

## 2. Naming

| Prefix | Contains | Must not contain |
|--------|----------|-----------------|
| `fact_` | measures, foreign keys to dims | descriptive attributes |
| `dim_` | descriptive attributes, surrogate key, natural key | measures |
| `int_` | intermediate joins/logic | direct BI consumption |
| `stg_` | renamed/cast raw columns | business logic |

## 3. Keys

### Dimension tables
- Must have a **surrogate key**: generated with `dbt_utils.generate_surrogate_key`, named `<entity>_key` (e.g. `port_key`)
- Must keep the **natural key** as a separate column, named `<entity>_natural_key` (e.g. `port_natural_key`)
- Surrogate key must have `not_null` + `unique` tests

### Fact tables
- Reference surrogate keys from dims only — never natural keys
- Must declare a grain key (surrogate or composite) with `not_null` + `unique` tests

## 4. Measures

- Measures in fact tables must be **additive** by default
- If a measure is semi-additive (e.g. a balance or gauge reading) or non-additive (e.g. a ratio), mark it explicitly in column docs
- Never put measures in dimension tables

## 5. Conformed dimensions

- Before creating a new `dim_` model, check whether a conformed dim already exists for that entity
- Conformed dims are reused across multiple fact tables — never duplicated with slightly different logic
- If a new dim is entity-specific and will not be reused, note this explicitly in the model description

## 6. Slowly Changing Dimensions (SCDs)

If a dimension attribute can change over time, the SCD type must be declared in the model description:

| Type | Behaviour |
|------|-----------|
| SCD 1 | Overwrite — no history kept |
| SCD 2 | New row per change — `valid_from` / `valid_to` + `is_current` flag |
| SCD hybrid | Some attributes Type 1, others Type 2 — document per column |

If an SCD type is not declared and attributes can change, treat it as a blocking issue.

## 7. Fact table shape

- No descriptive attributes in fact tables — they belong in dims
- No many-to-many grain (each fact row must map to exactly one value of each dimension)
- Degenerate dimensions (e.g. a transaction ID with no dim table) are allowed but must be documented

## 8. Role-playing dimensions

If the same dim is used multiple times in a fact table with different roles (e.g. `start_port` and `end_port` both referencing `dim_ports`), alias the join clearly and document the roles.
