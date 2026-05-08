# client.py
import argparse
import asyncio
import csv
import json
import logging
import random
import uuid
from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import websockets

from ocpp.v16 import ChargePoint as cp
from ocpp.v16 import call, call_result
from ocpp.v16.enums import RegistrationStatus


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


def read_ports(ports_path: Path, charge_point_id: str) -> list[int]:
    if not ports_path.exists():
        return [1]

    connector_ids: list[int] = []
    with ports_path.open("r", encoding="utf-8", newline="") as file:
        reader = csv.DictReader(file)
        for row in reader:
            if row.get("charge_point_id") != charge_point_id:
                continue
            connector_id = row.get("connector_id")
            if connector_id and connector_id.isdigit():
                connector_ids.append(int(connector_id))

    return sorted(set(connector_ids)) or [1]


class ChargePoint(cp):
    def __init__(self, charge_point_id: str, connection: websockets.ClientConnection):
        super().__init__(charge_point_id, connection)
        self.charge_point_id = charge_point_id
        self.current_transaction_id: int | None = None
        self.current_meter_wh = random.randint(2_300_000, 2_305_000)

    async def send_boot_notification(self):
        request_payload = {
            "chargePointVendor": "ACME",
            "chargePointModel": "UltraFast-200",
            "chargePointSerialNumber": f"UF200-{random.randint(1, 9999):04d}",
            "firmwareVersion": "1.6.7",
        }
        request = call.BootNotification(
            charge_point_vendor=request_payload["chargePointVendor"],
            charge_point_model=request_payload["chargePointModel"],
            charge_point_serial_number=request_payload["chargePointSerialNumber"],
            firmware_version=request_payload["firmwareVersion"],
        )
        response: call_result.BootNotification = await self.call(request)

        if response.status == RegistrationStatus.accepted:
            print("Connected to central system.")
        return request_payload, normalize_response_payload(response)

    async def send_heartbeat(self) -> tuple[dict[str, Any], dict[str, Any]]:
        request_payload: dict[str, Any] = {}
        response: call_result.Heartbeat = await self.call(call.Heartbeat())
        return request_payload, normalize_response_payload(response)

    async def send_status_notification(
        self, connector_id: int, status: str, error_code: str = "NoError"
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        request_payload = {
            "connectorId": connector_id,
            "status": status,
            "errorCode": error_code,
            "timestamp": format_utc_z(),
        }
        if error_code != "NoError":
            request_payload["info"] = "Synthetic connector issue"

        request = call.StatusNotification(
            connector_id=request_payload["connectorId"],
            status=request_payload["status"],
            error_code=request_payload["errorCode"],
            timestamp=request_payload["timestamp"],
            info=request_payload.get("info"),
        )
        response: call_result.StatusNotification = await self.call(request)
        return request_payload, normalize_response_payload(response)

    async def send_start_transaction(
        self, connector_id: int, id_tag: str
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        request_payload = {
            "connectorId": connector_id,
            "idTag": id_tag,
            "timestamp": format_utc_z(),
            "meterStart": self.current_meter_wh,
        }
        request = call.StartTransaction(
            connector_id=request_payload["connectorId"],
            id_tag=request_payload["idTag"],
            timestamp=request_payload["timestamp"],
            meter_start=request_payload["meterStart"],
        )
        response: call_result.StartTransaction = await self.call(request)
        response_payload = normalize_response_payload(response)
        self.current_transaction_id = int(response_payload["transactionId"])
        return request_payload, response_payload

    async def send_meter_values(self, connector_id: int) -> tuple[dict[str, Any], dict[str, Any]]:
        self.current_meter_wh += random.randint(20, 120)
        timestamp = format_utc_z()
        request = call.MeterValues(
            connector_id=connector_id,
            transaction_id=self.current_transaction_id,
            meter_value=[
                {
                    "timestamp": timestamp,
                    "sampled_value": [
                        {
                            "value": str(self.current_meter_wh),
                            "context": "Sample.Periodic",
                            "measurand": "Energy.Active.Import.Register",
                            "unit": "Wh",
                        }
                    ],
                }
            ],
        )
        response: call_result.MeterValues = await self.call(request)
        request_payload = {
            "connectorId": connector_id,
            "transactionId": self.current_transaction_id,
            "meterValue": [
                {
                    "timestamp": timestamp,
                    "sampledValue": [
                        {
                            "value": str(self.current_meter_wh),
                            "context": "Sample.Periodic",
                            "measurand": "Energy.Active.Import.Register",
                            "unit": "Wh",
                        }
                    ],
                }
            ],
        }
        return request_payload, normalize_response_payload(response)

    async def send_stop_transaction(self) -> tuple[dict[str, Any], dict[str, Any]]:
        stop_wh = self.current_meter_wh + random.randint(1, 30)
        transaction_data = [
            {
                "timestamp": format_utc_z(),
                "sampledValue": [
                    {
                        "context": "Transaction.End",
                        "measurand": "Energy.Active.Import.Register",
                        "value": str(stop_wh),
                        "unit": "Wh",
                    }
                ],
            }
        ]
        request_payload = {
            "transactionId": self.current_transaction_id,
            "meterStop": stop_wh,
            "timestamp": format_utc_z(),
            "reason": "EVDisconnected",
            "transactionData": transaction_data,
        }
        request = call.StopTransaction(
            transaction_id=request_payload["transactionId"],
            meter_stop=request_payload["meterStop"],
            timestamp=request_payload["timestamp"],
            reason=request_payload["reason"],
            transaction_data=transaction_data,
        )
        response: call_result.StopTransaction = await self.call(request)
        return request_payload, normalize_response_payload(response)

    async def send_repeated_actions(
        self,
        loops: int,
        interval_s: float,
        connector_id: int,
        log_writer: "SessionLogWriter",
        status_every: int,
        fault_probability: float,
    ) -> None:
        for index in range(1, loops + 1):
            if status_every > 0 and index % status_every == 0:
                preparing_req, preparing_res = await self.send_status_notification(
                    connector_id=connector_id, status="Preparing"
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=preparing_req,
                    response_payload=preparing_res,
                    msg_prefix="notif",
                )
                charging_req, charging_res = await self.send_status_notification(
                    connector_id=connector_id, status="Charging"
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=charging_req,
                    response_payload=charging_res,
                    msg_prefix="notif",
                )

            if random.random() < fault_probability:
                fault_req, fault_res = await self.send_status_notification(
                    connector_id=connector_id,
                    status="Faulted",
                    error_code="ConnectorLockFailure",
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=fault_req,
                    response_payload=fault_res,
                    msg_prefix="notif",
                )
                recover_req, recover_res = await self.send_status_notification(
                    connector_id=connector_id, status="Available"
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=recover_req,
                    response_payload=recover_res,
                    msg_prefix="notif",
                )
                resume_req, resume_res = await self.send_status_notification(
                    connector_id=connector_id, status="Charging"
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=resume_req,
                    response_payload=resume_res,
                    msg_prefix="notif",
                )

            hb_req, hb_res = await self.send_heartbeat()
            log_writer.log_exchange(
                charge_point_id=self.charge_point_id,
                action="Heartbeat",
                request_payload=hb_req,
                response_payload=hb_res,
                msg_prefix="hb",
            )
            meter_req, meter_res = await self.send_meter_values(connector_id)
            log_writer.log_exchange(
                charge_point_id=self.charge_point_id,
                action="MeterValues",
                request_payload=meter_req,
                response_payload=meter_res,
                msg_prefix="meter",
            )
            await asyncio.sleep(interval_s)


class SessionLogWriter:
    def __init__(self, output: Path):
        self.output = output
        self.file = output.open("w", encoding="utf-8", newline="")
        self.writer = csv.DictWriter(self.file, fieldnames=["timestamp", "id", "action", "msg"])
        self.writer.writeheader()

    def close(self) -> None:
        self.file.close()

    def _write_row(self, timestamp: str, charge_point_id: str, action: str, msg: list[Any]) -> None:
        self.writer.writerow(
            {
                "timestamp": timestamp,
                "id": charge_point_id,
                "action": action,
                "msg": json.dumps(msg, separators=(",", ":")),
            }
        )

    def log_exchange(
        self,
        charge_point_id: str,
        action: str,
        request_payload: dict[str, Any],
        response_payload: dict[str, Any],
        msg_prefix: str,
    ) -> None:
        msg_id = f"{msg_prefix}-{uuid.uuid4().hex[:5]}"
        request_time = format_utc_z()
        response_time = format_utc_z(datetime.now(timezone.utc))
        self._write_row(request_time, charge_point_id, action, [2, msg_id, action, request_payload])
        self._write_row(response_time, charge_point_id, "", [3, msg_id, response_payload])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run OCPP charge point client traffic.")
    parser.add_argument(
        "--loops",
        type=int,
        default=10,
        help="How many heartbeat/meter cycles to send (default: 10).",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=1.0,
        help="Delay between cycles in seconds (default: 1.0).",
    )
    parser.add_argument(
        "--charge-point-id",
        default="CH-002",
        help="Charge point id used in URL and output logs (default: CH-002).",
    )
    parser.add_argument(
        "--ports-file",
        type=Path,
        default=Path("ports.csv"),
        help="Ports CSV used to derive connector ids (default: ports.csv).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("ocpp_client_generated_logs.csv"),
        help="Output CSV path with columns timestamp,id,action,msg.",
    )
    parser.add_argument(
        "--status-every",
        type=int,
        default=10,
        help="Emit Preparing/Charging StatusNotification every N loops (default: 10).",
    )
    parser.add_argument(
        "--fault-probability",
        type=float,
        default=0.05,
        help="Chance of a fault/recovery status sequence per loop (default: 0.05).",
    )
    return parser.parse_args()


async def main(
    loops: int,
    interval_s: float,
    charge_point_id: str,
    ports_file: Path,
    output: Path,
    status_every: int,
    fault_probability: float,
):
    connector_ids = read_ports(ports_file, charge_point_id)
    log_writer = SessionLogWriter(output)
    start_task: asyncio.Task | None = None
    async with websockets.connect(
        f"ws://localhost:9000/{charge_point_id}", subprotocols=["ocpp2.0.1"]
    ) as ws:
        charge_point = ChargePoint(charge_point_id, ws)
        start_task = asyncio.create_task(charge_point.start())

        boot_req, boot_res = await charge_point.send_boot_notification()
        log_writer.log_exchange(
            charge_point_id=charge_point_id,
            action="BootNotification",
            request_payload=boot_req,
            response_payload=boot_res,
            msg_prefix="boot",
        )

        for connector_id in connector_ids:
            sn_req, sn_res = await charge_point.send_status_notification(
                connector_id=connector_id, status="Available"
            )
            log_writer.log_exchange(
                charge_point_id=charge_point_id,
                action="StatusNotification",
                request_payload=sn_req,
                response_payload=sn_res,
                msg_prefix="notif",
            )

        connector_id = connector_ids[0]
        start_req, start_res = await charge_point.send_start_transaction(
            connector_id=connector_id,
            id_tag=f"ABC{random.randint(100, 999)}XYZ",
        )
        log_writer.log_exchange(
            charge_point_id=charge_point_id,
            action="StartTransaction",
            request_payload=start_req,
            response_payload=start_res,
            msg_prefix="tx",
        )

        charging_req, charging_res = await charge_point.send_status_notification(
            connector_id=connector_id, status="Charging"
        )
        log_writer.log_exchange(
            charge_point_id=charge_point_id,
            action="StatusNotification",
            request_payload=charging_req,
            response_payload=charging_res,
            msg_prefix="notif",
        )

        await charge_point.send_repeated_actions(
            loops=loops,
            interval_s=interval_s,
            connector_id=connector_id,
            log_writer=log_writer,
            status_every=status_every,
            fault_probability=fault_probability,
        )

        stop_req, stop_res = await charge_point.send_stop_transaction()
        log_writer.log_exchange(
            charge_point_id=charge_point_id,
            action="StopTransaction",
            request_payload=stop_req,
            response_payload=stop_res,
            msg_prefix="stop",
        )

        final_req, final_res = await charge_point.send_status_notification(
            connector_id=connector_id, status="Available"
        )
        log_writer.log_exchange(
            charge_point_id=charge_point_id,
            action="StatusNotification",
            request_payload=final_req,
            response_payload=final_res,
            msg_prefix="notif",
        )

        await ws.close()
    try:
        if start_task is not None:
            await start_task
    except websockets.exceptions.ConnectionClosed:
        # Expected when we close the socket after finishing traffic generation.
        pass
    finally:
        log_writer.close()


if __name__ == "__main__":
    args = parse_args()
    configure_logging()
    asyncio.run(
        main(
            loops=args.loops,
            interval_s=args.interval,
            charge_point_id=args.charge_point_id,
            ports_file=args.ports_file,
            output=args.output,
            status_every=args.status_every,
            fault_probability=args.fault_probability,
        )
    )
