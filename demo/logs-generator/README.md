# OCPP Log Simulator

Simple OCPP server/client simulator for generating synthetic charger logs.

Two protocol versions are available:

| Version | Server | Client |
|---|---|---|
| OCPP 2.0.1 | `server.py` | `client.py` |
| OCPP 1.6 | `server1_6.py` | `client1_6.py` |

Both servers listen on port 9000, so run only one server at a time.

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
python client.py --loops 100 --interval 0.2 --charge-point-id CH-001 --response-delay-ms 40 --response-delay-jitter-ms 0 --output ocpp_client_generated_logs.csv
```

OCPP 1.6:

```bash
python client1_6.py --loops 100 --interval 0.2 --charge-point-id CH-001 --output ocpp_client_generated_logs.csv
```

Each client runs one scripted session: boot, Available status for every connector, start transaction, a loop of heartbeats and meter values (with occasional status changes and faults), stop transaction, final Available status. It writes a CSV with columns `timestamp,id,action,msg`, where every exchange is one request row and one response row.

## Client options

| Option | Default | Clients | Description |
|---|---|---|---|
| `--loops` | `10` | both | Number of heartbeat/meter cycles to send. |
| `--interval` | `1.0` | both | Delay between cycles, in seconds. |
| `--charge-point-id` | `CH-002` | both | Charge point id, used in the websocket URL and in the output `id` column. |
| `--ports-file` | `ports.csv` | both | Ports CSV used to look up the connectors of the charge point (see below). |
| `--output` | `ocpp_client_generated_logs.csv` | both | Output CSV path. |
| `--status-every` | `10` | both | Emit a Preparing then Charging StatusNotification every N loops. `0` disables it. |
| `--fault-probability` | `0.05` | both | Chance per loop of a Faulted, Available, Charging status sequence. `0` disables faults. |
| `--response-delay-ms` | `40` | both | Base spacing between request and response timestamps. |
| `--response-delay-jitter-ms` | `10` | both | Random extra delay (0 to N ms) added to the response timestamp. |

### Ports file

`--ports-file` points to a CSV with the columns `charge_point_id`, `connector_id` and (2.0.1 only) `port_id`. Rows are filtered by `--charge-point-id`.

- A StatusNotification (Available) is sent for every matching connector at startup.
- The charging session itself runs on the first connector only.
- `port_id` is used as the EVSE id in 2.0.1 and defaults to `1` if missing.
- If the file does not exist, or no row matches the charge point, the client falls back to a single connector `1`.

The default path is relative to the current directory, so run the client from the folder that contains `ports.csv` or pass an absolute path.
