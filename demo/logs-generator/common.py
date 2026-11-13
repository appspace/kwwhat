# common.py
"""Shared code for the OCPP 1.6 and 2.0.1 log generator clients.

The generator simulates one charger over a period of simulated time. The
websocket traffic itself runs as fast as possible, while every timestamp comes
from a simulated clock, so a day of charging takes a few seconds to generate.
"""
import argparse
import asyncio
import csv
import hashlib
import json
import logging
import math
import random
from collections import defaultdict
from dataclasses import asdict, dataclass, is_dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

import websockets

DEFAULT_CONNECTORS_FILE = Path(__file__).resolve().parent.parent / "seeds" / "connectors.csv"
DEFAULT_VENDOR_CODES_FILE = Path(__file__).resolve().parents[2] / "seeds" / "chargex_mrec_codes.csv"
DEFAULT_MAX_POWER_KW = 50.0
# Faults reported with a plain OCPP 1.6 errorCode only, no vendor code.
PLAIN_FAULT_ERROR_CODES = [
    "ConnectorLockFailure",
    "GroundFailure",
    "HighTemperature",
    "OverCurrentFailure",
    "PowerSwitchFailure",
    "OverVoltage",
]
# Faults that have a standard OCPP 1.6 equivalent are far more common than the exotic ones.
STANDARD_FAULT_WEIGHT = 3
EXOTIC_FAULT_WEIGHT = 1
# (vendor, model, serial prefix, firmware version)
VENDOR_CATALOG = [
    ("ABB", "Terra 184", "TA", "1.9.4"),
    ("Kempower", "C500", "KP", "3.2.1"),
    ("Tritium", "RTM75", "TR", "2.4.0"),
    ("Alpitronic", "HYC300", "AL", "1.7.2"),
    ("Delta", "UFC 500", "DL", "2.1.8"),
]
# Relative chance of a driver arriving in each hour of the day (UTC): quiet nights,
# a morning bump, a lunch bump and an evening peak.
HOURLY_ARRIVAL_WEIGHTS = [
    0.10, 0.05, 0.05, 0.05, 0.10, 0.20, 0.50, 0.90, 1.20, 1.00, 0.90, 1.00,
    1.30, 1.20, 1.00, 1.00, 1.20, 1.60, 1.80, 1.50, 1.00, 0.60, 0.30, 0.15,
]


def configure_logging() -> None:
    # force=True ensures config is applied even if logging was set elsewhere.
    logging.basicConfig(level=logging.INFO, force=True)
    logging.getLogger("ocpp").setLevel(logging.INFO)


def format_utc_z(dt: datetime | None = None) -> str:
    value = dt or datetime.now(timezone.utc)
    return value.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def snake_to_camel(name: str) -> str:
    parts = name.split("_")
    return parts[0] + "".join(part.capitalize() for part in parts[1:])


def to_camel(value: Any) -> Any:
    if isinstance(value, dict):
        return {snake_to_camel(k): to_camel(v) for k, v in value.items()}
    if isinstance(value, list):
        return [to_camel(item) for item in value]
    return value


def normalize_response_payload(response: Any) -> dict[str, Any]:
    if is_dataclass(response):
        return to_camel(asdict(response))
    return {}


@dataclass(frozen=True)
class ChargerIdentity:
    vendor: str
    model: str
    serial_number: str
    firmware_version: str


def charger_identity(charge_point_id: str) -> ChargerIdentity:
    """Vendor, model, serial and firmware of a charger, stable for a given charge point id.

    Derived from a hash of the id (not from --seed), so CH-001 is always the same make.
    """
    digest = int.from_bytes(hashlib.sha256(charge_point_id.encode("utf-8")).digest()[:8], "big")
    vendor, model, serial_prefix, firmware_version = VENDOR_CATALOG[digest % len(VENDOR_CATALOG)]
    serial_number = f"{serial_prefix}-{digest // len(VENDOR_CATALOG) % 1_000_000:06d}"
    return ChargerIdentity(
        vendor=vendor,
        model=model,
        serial_number=serial_number,
        firmware_version=firmware_version,
    )


@dataclass(frozen=True)
class Fault:
    """A connector fault as reported in StatusNotification (OCPP 1.6 only reports it)."""

    error_code: str
    vendor_id: str | None = None
    vendor_error_code: str | None = None


def read_vendor_faults(vendor_codes_path: Path) -> tuple[list[Fault], list[int]]:
    """Read vendor faults and their selection weights from a chargex_mrec_codes.csv style file.

    Expected columns: taxonomy, fault_code and optionally ocpp_1_6_error_code. Faults without
    a standard OCPP 1.6 equivalent are reported with the generic errorCode OtherError.
    Returns empty lists when the file is missing.
    """
    faults: list[Fault] = []
    weights: list[int] = []
    if not vendor_codes_path.exists():
        return faults, weights
    with vendor_codes_path.open("r", encoding="utf-8", newline="") as file:
        for row in csv.DictReader(file):
            if not row.get("taxonomy") or not row.get("fault_code"):
                continue
            standard_error_code = row.get("ocpp_1_6_error_code") or ""
            faults.append(
                Fault(
                    error_code=standard_error_code or "OtherError",
                    vendor_id=row["taxonomy"],
                    vendor_error_code=row["fault_code"],
                )
            )
            weights.append(STANDARD_FAULT_WEIGHT if standard_error_code else EXOTIC_FAULT_WEIGHT)
    return faults, weights


@dataclass(frozen=True)
class Connector:
    port_id: int
    connector_id: int
    max_power_kw: float


def read_connectors(connectors_path: Path, charge_point_id: str) -> list[Connector]:
    """Read the connectors of one charger from a connectors.csv style file.

    Expected columns: charge_point_id, port_id, connector_id and optionally max_power_kw.
    Falls back to a single connector when the file or the charger is missing.
    """
    fallback = [Connector(port_id=1, connector_id=1, max_power_kw=DEFAULT_MAX_POWER_KW)]
    if not connectors_path.exists():
        return fallback

    connectors: set[Connector] = set()
    with connectors_path.open("r", encoding="utf-8", newline="") as file:
        for row in csv.DictReader(file):
            if row.get("charge_point_id") != charge_point_id:
                continue
            connector_id_raw = row.get("connector_id")
            port_id_raw = row.get("port_id")
            if not connector_id_raw or not connector_id_raw.isdigit():
                continue
            power_raw = row.get("max_power_kw") or ""
            try:
                max_power_kw = float(power_raw)
            except ValueError:
                max_power_kw = DEFAULT_MAX_POWER_KW
            connectors.add(
                Connector(
                    port_id=int(port_id_raw) if port_id_raw and port_id_raw.isdigit() else 1,
                    connector_id=int(connector_id_raw),
                    max_power_kw=max_power_kw,
                )
            )
    return sorted(connectors, key=lambda c: (c.port_id, c.connector_id)) or fallback


class SessionLogWriter:
    """Collects exchanges in memory and writes them as one time-ordered CSV on close.

    Message ids are assigned in request time order, one counter per prefix.
    """

    def __init__(
        self,
        output: Path,
        response_delay_ms: int = 40,
        response_delay_jitter_ms: int = 10,
    ):
        self.output = output
        self.response_delay_ms = max(0, response_delay_ms)
        self.response_delay_jitter_ms = max(0, response_delay_jitter_ms)
        self.exchanges: list[dict[str, Any]] = []
        self.file = output.open("w", encoding="utf-8", newline="")
        self.writer = csv.DictWriter(self.file, fieldnames=["timestamp", "id", "action", "msg"])
        self.writer.writeheader()

    def log_exchange(
        self,
        charge_point_id: str,
        action: str,
        request_payload: dict[str, Any],
        response_payload: dict[str, Any],
        msg_prefix: str,
        request_dt: datetime,
    ) -> None:
        self.exchanges.append(
            {
                "charge_point_id": charge_point_id,
                "action": action,
                "request_payload": request_payload,
                "response_payload": response_payload,
                "msg_prefix": msg_prefix,
                "request_dt": request_dt,
            }
        )

    def close(self) -> None:
        counters: dict[str, int] = defaultdict(int)
        rows: list[tuple[datetime, dict[str, str]]] = []
        for exchange in sorted(self.exchanges, key=lambda e: e["request_dt"]):
            counters[exchange["msg_prefix"]] += 1
            msg_id = f"{exchange['msg_prefix']}-{counters[exchange['msg_prefix']]:05d}"
            request_dt = exchange["request_dt"]
            response_dt = request_dt + timedelta(
                milliseconds=self.response_delay_ms
                + random.randint(0, self.response_delay_jitter_ms)
            )
            request_msg = [2, msg_id, exchange["action"], exchange["request_payload"]]
            response_msg = [3, msg_id, exchange["response_payload"]]
            rows.append((request_dt, self._row(request_dt, exchange["charge_point_id"], exchange["action"], request_msg)))
            rows.append((response_dt, self._row(response_dt, exchange["charge_point_id"], "", response_msg)))
        rows.sort(key=lambda item: item[0])
        self.writer.writerows(row for _, row in rows)
        self.file.close()

    @staticmethod
    def _row(timestamp: datetime, charge_point_id: str, action: str, msg: list[Any]) -> dict[str, str]:
        return {
            "timestamp": format_utc_z(timestamp),
            "id": charge_point_id,
            "action": action,
            "msg": json.dumps(msg, separators=(",", ":")),
        }


@dataclass(frozen=True)
class SimulationConfig:
    start: datetime
    days: float
    sessions_per_port_per_day: float
    failed_attempt_probability: float
    fault_probability: float
    meter_interval_s: int
    heartbeat_interval_s: int
    vendor_faults: tuple[Fault, ...] = ()
    vendor_fault_weights: tuple[int, ...] = ()
    vendor_error_code_probability: float = 0.0

    @property
    def end(self) -> datetime:
        return self.start + timedelta(days=self.days)

    def pick_fault(self) -> Fault:
        if self.vendor_faults and random.random() < self.vendor_error_code_probability:
            return random.choices(self.vendor_faults, weights=self.vendor_fault_weights)[0]
        return Fault(error_code=random.choice(PLAIN_FAULT_ERROR_CODES))


async def _exchange(writer: SessionLogWriter, charge_point: Any, action: str, prefix: str, ts: datetime, call: Any) -> None:
    request_payload, response_payload = await call
    if "currentTime" in response_payload:
        # The server answers with wall-clock time, the log must show simulated time.
        response_payload = {**response_payload, "currentTime": format_utc_z(ts)}
    writer.log_exchange(
        charge_point_id=charge_point.charge_point_id,
        action=action,
        request_payload=request_payload,
        response_payload=response_payload,
        msg_prefix=prefix,
        request_dt=ts,
    )


async def _status(
    writer: SessionLogWriter,
    charge_point: Any,
    connector: Connector,
    status: str,
    ts: datetime,
    fault: Fault | None = None,
) -> None:
    await _exchange(
        writer, charge_point, "StatusNotification", "notif", ts,
        charge_point.send_status_notification(
            connector.port_id, connector.connector_id, status, ts, fault
        ),
    )


def _next_arrival(after: datetime, cfg: SimulationConfig) -> datetime:
    """Next driver arrival on a port, thinned by the hourly arrival profile."""
    max_weight = max(HOURLY_ARRIVAL_WEIGHTS)
    mean_weight = sum(HOURLY_ARRIVAL_WEIGHTS) / len(HOURLY_ARRIVAL_WEIGHTS)
    max_rate_per_s = cfg.sessions_per_port_per_day / 86400 * max_weight / mean_weight
    ts = after
    while True:
        ts += timedelta(seconds=random.expovariate(max_rate_per_s))
        if random.random() < HOURLY_ARRIVAL_WEIGHTS[ts.hour] / max_weight:
            return ts


async def _run_failed_attempt(
    writer: SessionLogWriter, charge_point: Any, connector: Connector, ts: datetime
) -> datetime:
    """Driver plugs in, nothing starts, driver gives up. No transaction."""
    await _status(writer, charge_point, connector, "Preparing", ts)
    free_at = ts + timedelta(seconds=random.randint(20, 120))
    await _status(writer, charge_point, connector, "Available", free_at)
    return free_at


async def _run_charge_session(
    writer: SessionLogWriter,
    charge_point: Any,
    cfg: SimulationConfig,
    connector: Connector,
    id_tag: str,
    ts: datetime,
) -> datetime:
    """One driver session. Returns the time the port is free again."""
    await _status(writer, charge_point, connector, "Preparing", ts)
    started_at = ts + timedelta(seconds=random.randint(5, 25))
    await _exchange(
        writer, charge_point, charge_point.start_action_name, "tx", started_at,
        charge_point.send_start_transaction(connector.port_id, connector.connector_id, id_tag, started_at),
    )
    await _status(writer, charge_point, connector, "Charging", started_at + timedelta(seconds=1))

    duration_s = 60 * min(180.0, max(5.0, random.lognormvariate(math.log(35), 0.6)))
    faulted = random.random() < cfg.fault_probability
    if faulted:
        duration_s *= random.uniform(0.2, 0.8)
    ended_at = started_at + timedelta(seconds=duration_s)
    energy_wh_per_s = connector.max_power_kw * random.uniform(0.4, 0.9) * 1000 / 3600

    meter_at = started_at + timedelta(seconds=cfg.meter_interval_s)
    last_sample_at = started_at
    while meter_at < ended_at:
        delta_wh = energy_wh_per_s * (meter_at - last_sample_at).total_seconds() * random.uniform(0.95, 1.05)
        await _exchange(
            writer, charge_point, "MeterValues", "meter", meter_at,
            charge_point.send_meter_values(connector.port_id, connector.connector_id, delta_wh, meter_at),
        )
        last_sample_at = meter_at
        meter_at += timedelta(seconds=cfg.meter_interval_s)

    remaining_wh = energy_wh_per_s * (ended_at - last_sample_at).total_seconds()
    await _exchange(
        writer, charge_point, charge_point.stop_action_name, "stop", ended_at,
        charge_point.send_stop_transaction(
            connector.port_id, connector.connector_id, ended_at,
            "Other" if faulted else "EVDisconnected", remaining_wh,
        ),
    )

    if faulted:
        faulted_at = ended_at + timedelta(seconds=1)
        await _status(writer, charge_point, connector, "Faulted", faulted_at, cfg.pick_fault())
        free_at = faulted_at + timedelta(minutes=random.uniform(10, 240))
    else:
        await _status(writer, charge_point, connector, "Finishing", ended_at + timedelta(seconds=1))
        free_at = ended_at + timedelta(seconds=random.randint(10, 60))
    await _status(writer, charge_point, connector, "Available", free_at)
    return free_at


async def _run_port(
    writer: SessionLogWriter,
    charge_point: Any,
    cfg: SimulationConfig,
    connectors: list[Connector],
    id_tags: list[str],
) -> None:
    """Run back to back sessions on one port. A port serves one driver at a time."""
    if cfg.sessions_per_port_per_day <= 0:
        return
    ts = cfg.start + timedelta(minutes=1)
    while True:
        ts = _next_arrival(ts, cfg)
        if ts >= cfg.end:
            return
        connector = random.choice(connectors)
        if random.random() < cfg.failed_attempt_probability:
            ts = await _run_failed_attempt(writer, charge_point, connector, ts)
        else:
            ts = await _run_charge_session(
                writer, charge_point, cfg, connector, random.choice(id_tags), ts
            )


async def run_simulation(
    charge_point: Any,
    writer: SessionLogWriter,
    cfg: SimulationConfig,
    connectors: list[Connector],
) -> None:
    await _exchange(
        writer, charge_point, "BootNotification", "boot", cfg.start,
        charge_point.send_boot_notification(),
    )
    for index, connector in enumerate(connectors):
        await _status(writer, charge_point, connector, "Available", cfg.start + timedelta(seconds=1 + index))

    heartbeat_at = cfg.start + timedelta(seconds=cfg.heartbeat_interval_s)
    while heartbeat_at < cfg.end:
        await _exchange(writer, charge_point, "Heartbeat", "hb", heartbeat_at, charge_point.send_heartbeat())
        heartbeat_at += timedelta(seconds=cfg.heartbeat_interval_s)

    id_tags = [f"ABC{number}XYZ" for number in random.sample(range(100, 1000), 25)]
    connectors_by_port: dict[int, list[Connector]] = defaultdict(list)
    for connector in connectors:
        connectors_by_port[connector.port_id].append(connector)
    for port_connectors in connectors_by_port.values():
        await _run_port(writer, charge_point, cfg, port_connectors, id_tags)


def _parse_start(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run OCPP charge point client traffic.")
    parser.add_argument(
        "--charge-point-id",
        default="CH-002",
        help="Charge point id used in URL and output logs (default: CH-002).",
    )
    parser.add_argument(
        "--connectors-file",
        type=Path,
        default=DEFAULT_CONNECTORS_FILE,
        help="Connectors CSV (charge_point_id, port_id, connector_id, max_power_kw) "
        "(default: ../seeds/connectors.csv).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("ocpp_client_generated_logs.csv"),
        help="Output CSV path with columns timestamp,id,action,msg.",
    )
    parser.add_argument(
        "--start",
        type=_parse_start,
        default=None,
        help="Simulated start time, ISO 8601, UTC if no zone (default: now minus --days).",
    )
    parser.add_argument(
        "--days",
        type=float,
        default=1.0,
        help="How many days of charger activity to simulate (default: 1).",
    )
    parser.add_argument(
        "--sessions-per-port-per-day",
        type=float,
        default=6.0,
        help="Average number of driver arrivals per port per day (default: 6).",
    )
    parser.add_argument(
        "--failed-attempt-probability",
        type=float,
        default=0.1,
        help="Chance that an arrival never starts a transaction (default: 0.1).",
    )
    parser.add_argument(
        "--fault-probability",
        type=float,
        default=0.05,
        help="Chance that a charging session ends in a fault with repair downtime (default: 0.05).",
    )
    parser.add_argument(
        "--vendor-codes-file",
        type=Path,
        default=DEFAULT_VENDOR_CODES_FILE,
        help="Vendor fault codes CSV (taxonomy, fault_code, ocpp_1_6_error_code) "
        "(default: ../../seeds/chargex_mrec_codes.csv). Used by OCPP 1.6 only.",
    )
    parser.add_argument(
        "--vendor-error-code-probability",
        type=float,
        default=0.8,
        help="Chance that a fault also reports vendorId and vendorErrorCode, "
        "otherwise only a plain errorCode (default: 0.8). OCPP 1.6 only.",
    )
    parser.add_argument(
        "--meter-interval",
        type=int,
        default=300,
        help="Seconds between MeterValues during a session (default: 300).",
    )
    parser.add_argument(
        "--heartbeat-interval",
        type=int,
        default=300,
        help="Seconds between Heartbeats (default: 300).",
    )
    parser.add_argument(
        "--response-delay-ms",
        type=int,
        default=40,
        help="Base response spacing in CSV rows (default: 40ms).",
    )
    parser.add_argument(
        "--response-delay-jitter-ms",
        type=int,
        default=10,
        help="Extra random response delay jitter in ms (default: 10).",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed for reproducible logs (default: random).",
    )
    return parser.parse_args()


async def run_client(args: argparse.Namespace, charge_point_cls: type, subprotocol: str) -> None:
    if args.seed is not None:
        random.seed(args.seed)
    start = args.start or (datetime.now(timezone.utc) - timedelta(days=args.days)).replace(microsecond=0)
    vendor_faults, vendor_fault_weights = read_vendor_faults(args.vendor_codes_file)
    cfg = SimulationConfig(
        start=start,
        days=args.days,
        sessions_per_port_per_day=args.sessions_per_port_per_day,
        failed_attempt_probability=args.failed_attempt_probability,
        fault_probability=args.fault_probability,
        meter_interval_s=max(1, args.meter_interval),
        heartbeat_interval_s=max(1, args.heartbeat_interval),
        vendor_faults=tuple(vendor_faults),
        vendor_fault_weights=tuple(vendor_fault_weights),
        vendor_error_code_probability=args.vendor_error_code_probability,
    )
    connectors = read_connectors(args.connectors_file, args.charge_point_id)
    writer = SessionLogWriter(
        args.output,
        response_delay_ms=args.response_delay_ms,
        response_delay_jitter_ms=args.response_delay_jitter_ms,
    )
    start_task: asyncio.Task | None = None
    try:
        async with websockets.connect(
            f"ws://localhost:9000/{args.charge_point_id}", subprotocols=[subprotocol]
        ) as ws:
            charge_point = charge_point_cls(args.charge_point_id, ws)
            start_task = asyncio.create_task(charge_point.start())
            await run_simulation(charge_point, writer, cfg, connectors)
            await ws.close()
        try:
            await start_task
        except websockets.exceptions.ConnectionClosed:
            # Expected when we close the socket after finishing traffic generation.
            pass
    finally:
        writer.close()
