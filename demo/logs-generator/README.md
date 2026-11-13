# OCPP Log Simulator

Simple OCPP server/client simulator for generating synthetic charger logs.

One server and one client speak both OCPP 1.6 and OCPP 2.0.1. The client picks the version with `--ocpp-version`, and the server follows whatever the client asks for in the websocket handshake.

| File | Role |
|---|---|
| `server.py` | Central system on port 9000, serves both versions |
| `client.py` | Charge point simulator, `--ocpp-version 1.6` (default) or `2.0.1` |
| `common.py` | Code shared by both versions (simulation, CLI, CSV writer) |
| `central_system_v16.py`, `central_system_v201.py` | Server side message handlers per version |
| `charge_point_v16.py`, `charge_point_v201.py` | Client side messages per version |

## Installation

```bash
pip install -r requirements.txt
```

## Run server

```bash
python server.py
```

## Run client

OCPP 1.6 (default):

```bash
python client.py --charge-point-id CH-001 --days 7 --start 2025-11-01T00:00:00Z --seed 42 --output ocpp_client_generated_logs.csv
```

OCPP 2.0.1:

```bash
python client.py --ocpp-version 2.0.1 --charge-point-id CH-001 --days 7 --start 2025-11-01T00:00:00Z --seed 42 --output ocpp_client_generated_logs.csv
```

## What a run simulates

One client run simulates one charger over `--days` of simulated time. The websocket traffic runs as fast as possible and every timestamp comes from a simulated clock, so a week of activity takes a few seconds to generate.

- **Startup:** BootNotification, then an Available StatusNotification for every connector of the charger.
- **Charger identity:** the BootNotification carries a vendor, model, serial number and firmware version picked from a small built-in catalog (`VENDOR_CATALOG` in `common.py`). The pick depends only on `--charge-point-id`, so a charger is always the same make, even across runs and regardless of `--seed`.
- **Heartbeats:** one every `--heartbeat-interval` seconds for the whole period.
- **Driver arrivals:** every port gets about `--sessions-per-port-per-day` arrivals per day, spread over the day with quiet nights and morning, lunch and evening peaks.
- **One driver per port:** a port never serves two drivers at once, and each arrival picks a random connector of the port. Different ports charge at the same time.
- **Charging session:** Preparing, start transaction, Charging, MeterValues every `--meter-interval` seconds, stop transaction, Finishing, Available. Session length varies (median about 35 minutes) and the energy delivered depends on the connector's `max_power_kw`.
- **Failed attempt:** with `--failed-attempt-probability`, the driver plugs in (Preparing) and leaves a minute or two later (Available) without a transaction.
- **Fault:** with `--fault-probability`, a session ends early with stop reason `Other`, the connector goes Faulted and returns to Available after 10 minutes to 4 hours of repair downtime. In OCPP 1.6 the Faulted StatusNotification carries an `errorCode`, and with `--vendor-error-code-probability` it also carries `vendorId` and `vendorErrorCode` taken from `--vendor-codes-file` (ChargeX codes such as `CX003`). Codes without a standard OCPP 1.6 equivalent are sent with `errorCode` `OtherError`. OCPP 2.0.1 StatusNotification has no error fields, so 2.0.1 faults only show the Faulted status.

All ports and the heartbeat run concurrently against the simulated clock, and requests reach the server in timestamp order. That is why the OCPP 1.6 transaction ids assigned by the server increase with time, as they would on a real central system.

## Lifecycle

The client reads `commissioned_ts` and `decommissioned_ts` of the charger from `--chargers-file` (default `../seeds/chargers.csv`) and only generates traffic inside that period, so the logs agree with the reference data dbt reads.

- The period is cut to the commissioned period. A run that starts before `commissioned_ts` starts at the commissioning time with a BootNotification.
- Nothing is sent after `decommissioned_ts` (a 1 second margin keeps the response rows inside too). A session that could not finish before the decommissioning is not started, so no transaction is ever left open.
- If the requested period has no overlap with the commissioned period, no connection is made and the output file has only the header. This is what a default run (last `--days` days, up to now) does for a charger decommissioned in the past.
- A blank `decommissioned_ts` means the charger is still in commission. A charger missing from the file has no limits.
- `--ignore-lifecycle` turns all of this off.

The demo seeds contain three chargers so that both situations can be generated:

| Charger | Lifecycle | Use |
|---|---|---|
| CH-001 | commissioned 2025-10-01, decommissioned 2025-10-15 | Replay the decommissioning scenario: `--start 2025-10-01T00:00:00Z --days 30` |
| CH-002 | commissioned 2025-09-15, still in commission | Live charger |
| CH-003 | commissioned 2025-10-01, still in commission | Live charger, same layout as CH-002, has no logs in the demo logs seed |

The output is a CSV with columns `timestamp,id,action,msg`, sorted by timestamp. Every exchange is one request row and one response row, and the response row is stamped `--response-delay-ms` plus jitter after the request. Message ids are sequential per message type (`hb-00001`, `notif-00001`). The `currentTime` in server responses is rewritten to the simulated time.

Use `--seed` together with `--start` for reproducible output. The OCPP 2.0.1 transaction ids are random UUID fragments, so those differ between runs.

## Client options

| Option | Default | Description |
|---|---|---|
| `--ocpp-version` | `1.6` | OCPP version to speak, `1.6` or `2.0.1`. |
| `--charge-point-id` | `CH-002` | Charge point id, used in the websocket URL and in the output `id` column. |
| `--connectors-file` | `../seeds/connectors.csv` | Connectors CSV, see below. |
| `--chargers-file` | `../seeds/chargers.csv` | Chargers CSV with commissioned and decommissioned dates, see Lifecycle below. |
| `--ignore-lifecycle` | off | Do not limit traffic to the charger's commissioned and decommissioned dates. |
| `--output` | `ocpp_client_generated_logs.csv` | Output CSV path. |
| `--start` | now minus `--days` | Simulated start time, ISO 8601. UTC if no zone is given. |
| `--days` | `1` | Days of charger activity to simulate. |
| `--sessions-per-port-per-day` | `6` | Average driver arrivals per port per day. `0` disables sessions. |
| `--failed-attempt-probability` | `0.1` | Chance that an arrival never starts a transaction. |
| `--fault-probability` | `0.05` | Chance that a charging session ends in a fault. |
| `--vendor-codes-file` | `../../seeds/chargex_mrec_codes.csv` | Vendor fault codes CSV (`taxonomy`, `fault_code`, `ocpp_1_6_error_code`). Used by OCPP 1.6 only. If the file is missing, faults carry no vendor code. |
| `--vendor-error-code-probability` | `0.8` | Chance that a fault also reports `vendorId` and `vendorErrorCode`. Otherwise only a plain `errorCode`. OCPP 1.6 only. |
| `--meter-interval` | `300` | Seconds between MeterValues during a session. |
| `--heartbeat-interval` | `300` | Seconds between Heartbeats. |
| `--response-delay-ms` | `40` | Base spacing between request and response timestamps. |
| `--response-delay-jitter-ms` | `10` | Random extra delay (0 to N ms) added to the response timestamp. |
| `--seed` | random | Random seed for reproducible logs. |

### Connectors file

`--connectors-file` points to a CSV like `demo/seeds/connectors.csv` with the columns `charge_point_id`, `port_id`, `connector_id` and `max_power_kw`. Rows are filtered by `--charge-point-id`.

- Connectors of the same `port_id` share one port, so only one of them is in use at a time.
- `port_id` is used as the EVSE id in 2.0.1. OCPP 1.6 has no EVSE concept, so only `connector_id` is sent.
- `max_power_kw` drives the energy delivered per session. It defaults to 50 if missing.
- If the file does not exist, or no row matches the charger, the client falls back to a single connector 1 on port 1.
