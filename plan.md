# Ports refactor

Split the single `stg_ports` (connector grain, all columns) into three entity-grain staging models, with a matching intermediate transfer model per entity.

---

## Staging

| Model | Was | Now |
|---|---|---|
| `stg_ports` | Connector grain, all 7 columns | Deleted |
| `stg_chargers` | — | New. Charger grain: `charge_point_id`, `location_id`, `commissioned_ts`, `decommissioned_ts` |
| `stg_ports` | — | New. Port grain: `charge_point_id`, `port_id` |
| `stg_connectors` | — | New. Connector grain: `charge_point_id`, `port_id`, `connector_id`, `connector_type` |

`commissioned_ts` / `decommissioned_ts` sit on `stg_chargers` because they track when the physical station was activated, not the port or connector.

---

## Intermediate

### New transfer models

Each intermediate model is a table materialization that breaks the live RAW catalog dependency for downstream views and incremental models.

| Model | Source | Grain |
|---|---|---|
| `int_chargers` | `stg_chargers` | `charge_point_id` |
| `int_ports` | `stg_ports` | `charge_point_id + port_id` |
| `int_connectors` | `stg_connectors` | `charge_point_id + port_id + connector_id` |

`int_ports` previously held all 7 columns at connector grain. It is now a simple transfer at port grain.

### Updated models

**`int_status_changes`** — join target changed from `int_ports` to `int_connectors`. The join resolves `connector_id → port_id`; `int_connectors` is the correct grain for that lookup.

**`int_faulted_outages`** — ref changed from `int_ports` to `int_connectors`. Connector count per port comes from `int_connectors`.

**`int_offline_outages`** — ref changed from `int_ports` to `int_chargers`. Commissioning window (`commissioned_ts`, `decommissioned_ts`) is a charger attribute; `min`/`max` aggregation removed since `int_chargers` is already at charger grain.

---

## Marts

| Model | Change |
|---|---|
| `dim_charge_points` | Reads `location_id`, `commissioned_ts`, `decommissioned_ts` from `int_chargers`; joins `int_ports` for `port_count` only |
| `dim_connectors` | Reads from `int_connectors` only; `location_id` removed (not a connector attribute) |
| `dim_ports` | Reads from `int_connectors` only; `location_id` removed (not a port attribute) |
| `dim_locations` | Reads from `int_chargers` instead of `int_ports` |
| `fact_location_capacity` | Reads from `int_connectors`; joins `int_chargers` for `location_id` |
| `charge_point_span_daily` | Reads from `int_chargers`; `min`/`max` aggregation removed |

### Outstanding

**`fact_visits`** joins `dim_connectors` for `location_id` (line 41), which no longer carries that column. Needs to be re-pointed — likely to `dim_charge_points` or `int_chargers` via `charge_point_id`.
