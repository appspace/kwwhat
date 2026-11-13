# OCPP Log Simulator

Simple OCPP server/client simulator for generating synthetic charger logs.

Two protocol versions are available:

| Version | Server | Client |
|---|---|---|
| OCPP 2.0.1 | `server.py` | `client.py` |
| OCPP 1.6 | `server1_6.py` | `client1_6.py` |

Both servers listen on port 9000, so run only one server at a time. `common.py` holds the code shared by both clients (simulation, CLI, CSV writer).

## Installation

```bash
pip install -r requirements.txt
```

## Run server

OCPP 2.0.1:

```bash
python server.py
```

OCPP 1.6:

```bash
python server1_6.py
```

## Run client

OCPP 2.0.1:

```bash
python client.py --charge-point-id CH-001 --days 7 --start 2025-11-01T00:00:00Z --seed 42 --output ocpp_client_generated_logs.csv
```

OCPP 1.6:

```bash
python client1_6.py --charge-point-id CH-001 --days 7 --start 2025-11-01T00:00:00Z --seed 42 --output ocpp_client_generated_logs.csv
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

The output is a CSV with columns `timestamp,id,action,msg`, sorted by timestamp. Every exchange is one request row and one response row, and the response row is stamped `--response-delay-ms` plus jitter after the request. Message ids are sequential per message type (`hb-00001`, `notif-00001`). The `currentTime` in server responses is rewritten to the simulated time.

Use `--seed` together with `--start` for reproducible output. The OCPP 2.0.1 transaction ids are random UUID fragments, so those differ between runs.

## Client options

| Option | Default | Description |
|---|---|---|
| `--charge-point-id` | `CH-002` | Charge point id, used in the websocket URL and in the output `id` column. |
| `--connectors-file` | `../seeds/connectors.csv` | Connectors CSV, see below. |
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
