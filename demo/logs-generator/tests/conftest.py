"""Shared fixtures for the log generator tests.

The tests run the real client (client.PROTOCOLS + common.run_client) against the real central
system classes (server.CHARGE_POINT_CLASSES), connected by an in-memory pipe instead of a
websocket. Every request still goes through the ocpp library, including its JSON schema
validation, but no server process or network port is needed.
"""
import asyncio
import csv
import itertools
import json
import sys
from collections import defaultdict
from contextlib import asynccontextmanager
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest
import websockets

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import central_system_v16  # noqa: E402
import common  # noqa: E402
from auth_list import AuthList  # noqa: E402
from client import PROTOCOLS  # noqa: E402
from server import CHARGE_POINT_CLASSES  # noqa: E402

START = "2025-11-01T00:00:00Z"

# Test charger layout: CH-T1 has two ports with two connectors each, CH-T2 one port with a
# single connector. Lifecycle chargers have the same layout as CH-T1.
CONNECTORS_CSV = """charge_point_id,port_id,connector_id,connector_type,max_power_kw
CH-T1,1,1,CCS,150
CH-T1,1,2,NACS,150
CH-T1,2,3,CCS,50
CH-T1,2,4,CHAdeMO,50
CH-T2,1,1,CCS,150
CH-NEW,1,1,CCS,150
CH-NEW,1,2,NACS,150
CH-OLD,1,1,CCS,150
CH-OLD,1,2,NACS,150
"""
CHARGERS_CSV = """charge_point_id,location_id,commissioned_ts,decommissioned_ts
CH-T1,LOC-T,2025-01-01T00:00:00.000Z,
CH-T2,LOC-T,2025-01-01T00:00:00.000Z,
CH-NEW,LOC-T,2025-11-02T08:00:00.000Z,
CH-OLD,LOC-T,2025-10-01T00:00:00.000Z,2025-11-02T12:00:00.000Z
"""
VENDOR_CODES_CSV = """taxonomy,fault_code,ocpp_1_6_error_code
https://chargex.inl.gov,CX002,GroundFailure
https://chargex.inl.gov,CX016,
"""


class _Closed:
    """Put on a pipe to tell the reader the connection is closed."""


CLOSED = _Closed()


class MemoryConnection:
    """One end of an in-memory websocket: just the send and recv the ocpp library uses."""

    def __init__(self, inbox: asyncio.Queue, peer_inbox: asyncio.Queue):
        self.inbox = inbox
        self.peer_inbox = peer_inbox

    async def send(self, message: str) -> None:
        await self.peer_inbox.put(message)

    async def recv(self) -> str:
        message = await self.inbox.get()
        if message is CLOSED:
            raise websockets.exceptions.ConnectionClosedOK(None, None)
        return message

    async def close(self) -> None:
        await self.inbox.put(CLOSED)
        await self.peer_inbox.put(CLOSED)


class MemoryServer:
    """Stands in for server.py and websockets.connect."""

    def __init__(self) -> None:
        self.connections = 0
        self.refuse = False
        self.restart()

    def restart(self, auth_list: Path | None = None) -> None:
        """Like restarting server.py (with --auth-list): OCPP 1.6 transaction ids start again at 5001."""
        central_system_v16.MyChargePoint._transaction_id_counter = itertools.count(5001)
        central_system_v16.MyChargePoint.auth_list = AuthList.read(auth_list) if auth_list else AuthList()

    @asynccontextmanager
    async def connect(self, uri: str, subprotocols: list[str]):
        if self.refuse:
            raise ConnectionRefusedError("test server refuses connections")
        self.connections += 1
        client_inbox, server_inbox = asyncio.Queue(), asyncio.Queue()
        client = MemoryConnection(client_inbox, server_inbox)
        central = CHARGE_POINT_CLASSES[subprotocols[0]](uri.rsplit("/", 1)[-1], MemoryConnection(server_inbox, client_inbox))
        task = asyncio.create_task(central.start())
        try:
            yield client
        finally:
            await client.close()
            try:
                await task
            except websockets.exceptions.ConnectionClosed:
                pass


@pytest.fixture
def server(monkeypatch) -> MemoryServer:
    memory_server = MemoryServer()
    monkeypatch.setattr(common.websockets, "connect", memory_server.connect)
    return memory_server


@pytest.fixture
def seeds(tmp_path) -> dict[str, Path]:
    paths = {
        "connectors": tmp_path / "connectors.csv",
        "chargers": tmp_path / "chargers.csv",
        "vendor_codes": tmp_path / "vendor_codes.csv",
    }
    paths["connectors"].write_text(CONNECTORS_CSV, encoding="utf-8")
    paths["chargers"].write_text(CHARGERS_CSV, encoding="utf-8")
    paths["vendor_codes"].write_text(VENDOR_CODES_CSV, encoding="utf-8")
    return paths


@pytest.fixture
def generate(server, seeds, tmp_path, monkeypatch):
    """Run the client with the given CLI options and return the parsed output log.

    The test seeds are used unless the options name other files, and the output defaults to
    out.csv in the test's temporary directory.
    """

    def run(*options: str) -> "Log":
        argv = list(options)
        defaults = {
            "--connectors-file": str(seeds["connectors"]),
            "--chargers-file": str(seeds["chargers"]),
            "--vendor-codes-file": str(seeds["vendor_codes"]),
            "--output": str(tmp_path / "out.csv"),
        }
        for option, value in defaults.items():
            if option not in argv:
                argv += [option, value]
        monkeypatch.setattr(sys, "argv", ["client.py", *argv])
        args = common.parse_args()
        charge_point_class, subprotocol = PROTOCOLS[args.ocpp_version]
        asyncio.run(common.run_client(args, charge_point_class, subprotocol))
        return Log(args.output)

    return run


@dataclass(frozen=True)
class Row:
    timestamp: datetime
    charge_point_id: str
    action: str
    message_type: int
    message_id: str
    payload: dict[str, Any]


@dataclass(frozen=True)
class Status:
    timestamp: datetime
    connector_id: int
    status: str
    payload: dict[str, Any]


class Log:
    """A generated CSV, parsed."""

    def __init__(self, path: Path):
        self.path = path
        with path.open(encoding="utf-8", newline="") as file:
            reader = csv.DictReader(file)
            self.header = reader.fieldnames
            self.raw_rows = list(reader)
        self.rows = []
        for raw in self.raw_rows:
            msg = json.loads(raw["msg"])
            self.rows.append(
                Row(
                    timestamp=common.parse_timestamp(raw["timestamp"]),
                    charge_point_id=raw["id"],
                    action=raw["action"],
                    message_type=msg[0],
                    message_id=msg[1],
                    payload=msg[3] if msg[0] == 2 else msg[2],
                )
            )

    def requests(self, action: str | None = None) -> list[Row]:
        return [row for row in self.rows if row.message_type == 2 and (action is None or row.action == action)]

    def responses(self) -> list[Row]:
        return [row for row in self.rows if row.message_type == 3]

    def response_to(self, request: Row) -> Row:
        return next(row for row in self.responses() if row.message_id == request.message_id)

    def statuses(self) -> list[Status]:
        """StatusNotifications in time order, with 1.6 status names (2.0.1 uses connectorStatus)."""
        result = []
        for row in self.requests("StatusNotification"):
            payload = row.payload
            result.append(
                Status(
                    timestamp=common.parse_timestamp(payload["timestamp"]),
                    connector_id=payload["connectorId"],
                    status=payload.get("status") or payload["connectorStatus"],
                    payload=payload,
                )
            )
        return result


def port_of(seeds: dict[str, Path], charge_point_id: str) -> dict[int, int]:
    """connector_id to port_id of one test charger."""
    return {c.connector_id: c.port_id for c in common.read_connectors(seeds["connectors"], charge_point_id)}


@dataclass(frozen=True)
class Visit:
    """One driver at a port, from Preparing until the port is free again (OCPP 1.6 statuses)."""

    port_id: int
    connector_id: int
    started_at: datetime
    ended_at: datetime
    faulted: bool


def replay_ports(log: Log, ports: dict[int, int]) -> tuple[list[Visit], list[tuple[int, datetime, datetime]], dict[int, str]]:
    """Replay OCPP 1.6 statuses and check that every port serves one driver at a time.

    Returns the driver visits, every repair as (connector_id, faulted_at, repaired_at), and the
    last status of every connector. Fails the test on a status sequence a real charger can't send.
    """
    last_status: dict[int, str] = {}
    driver_on_port: dict[int, tuple[int, datetime]] = {}
    faulted_at: dict[int, datetime] = {}
    visits: list[Visit] = []
    repairs: list[tuple[int, datetime, datetime]] = []
    for status in log.statuses():
        connector, port = status.connector_id, ports[status.connector_id]
        previous = last_status.get(connector)
        if status.status == "Preparing":
            assert previous == "Available", f"{status.timestamp}: Preparing on connector {connector} after {previous}"
            assert port not in driver_on_port, f"{status.timestamp}: second driver on port {port}"
            driver_on_port[port] = (connector, status.timestamp)
        elif status.status in ("Finishing", "Faulted") or (status.status == "Available" and previous == "Preparing"):
            driver_connector, started_at = driver_on_port.pop(port)
            assert driver_connector == connector
            visits.append(Visit(port, connector, started_at, status.timestamp, status.status == "Faulted"))
        if status.status == "Faulted":
            faulted_at[connector] = status.timestamp
        elif status.status == "Available" and previous == "Faulted":
            repairs.append((connector, faulted_at.pop(connector), status.timestamp))
        last_status[connector] = status.status
    assert not driver_on_port, f"drivers still on ports at the end: {driver_on_port}"
    return visits, repairs, last_status


def transactions(log: Log) -> dict[Any, dict[str, Any]]:
    """OCPP 1.6 transactions by id: start request, its response and stop request."""
    result: dict[Any, dict[str, Any]] = defaultdict(dict)
    for request in log.requests("StartTransaction"):
        transaction_id = log.response_to(request).payload["transactionId"]
        result[transaction_id]["start"] = request
    for request in log.requests("StopTransaction"):
        result[request.payload["transactionId"]]["stop"] = request
    return dict(result)
