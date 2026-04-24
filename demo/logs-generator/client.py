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

from ocpp.v201 import ChargePoint as cp
from ocpp.v201 import call, call_result, datatypes, enums


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


def read_ports(ports_path: Path, charge_point_id: str) -> list[tuple[int, int]]:
    if not ports_path.exists():
        return [(1, 1)]

    connectors: list[tuple[int, int]] = []
    with ports_path.open("r", encoding="utf-8", newline="") as file:
        reader = csv.DictReader(file)
        for row in reader:
            if row.get("charge_point_id") != charge_point_id:
                continue
            connector_id_raw = row.get("connector_id")
            evse_id_raw = row.get("port_id")
            if not connector_id_raw or not connector_id_raw.isdigit():
                continue
            connector_id = int(connector_id_raw)
            evse_id = int(evse_id_raw) if evse_id_raw and evse_id_raw.isdigit() else 1
            connectors.append((evse_id, connector_id))

    return sorted(set(connectors)) or [(1, 1)]


class ChargePoint(cp):
    def __init__(self, charge_point_id: str, connection: websockets.ClientConnection):
        super().__init__(charge_point_id, connection)
        self.charge_point_id = charge_point_id
        self.current_transaction_id: str | None = None
        self.current_meter_wh = random.randint(2_300_000, 2_305_000)
        self.transaction_seq_no = 0

    async def send_boot_notification(self):
        request_payload = {
            "chargingStation": {
                "vendorName": "ACME",
                "model": "UltraFast-200",
                "serialNumber": f"UF200-{random.randint(1, 9999):04d}",
                "firmwareVersion": "2.0.1",
            },
            "reason": "PowerUp",
        }
        request = call.BootNotification(
            charging_station=datatypes.ChargingStationType(
                vendor_name=request_payload["chargingStation"]["vendorName"],
                model=request_payload["chargingStation"]["model"],
                serial_number=request_payload["chargingStation"]["serialNumber"],
                firmware_version=request_payload["chargingStation"]["firmwareVersion"],
            ),
            reason=enums.BootReasonEnumType.power_up,
        )
        response: call_result.BootNotification = await self.call(request)

        if response.status == enums.RegistrationStatusEnumType.accepted:
            print("Connected to central system.")
        return request_payload, normalize_response_payload(response)

    async def send_heartbeat(self) -> tuple[dict[str, Any], dict[str, Any]]:
        request_payload: dict[str, Any] = {}
        response: call_result.Heartbeat = await self.call(call.Heartbeat())
        return request_payload, normalize_response_payload(response)

    async def send_status_notification(
        self, evse_id: int, connector_id: int, status: str
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        connector_status_map = {
            "Available": enums.ConnectorStatusEnumType.available,
            "Preparing": enums.ConnectorStatusEnumType.occupied,
            "Charging": enums.ConnectorStatusEnumType.occupied,
            "Faulted": enums.ConnectorStatusEnumType.faulted,
        }
        connector_status = connector_status_map.get(
            status, enums.ConnectorStatusEnumType.occupied
        )
        request_payload = {
            "timestamp": format_utc_z(),
            "connectorStatus": connector_status.value,
            "evseId": evse_id,
            "connectorId": connector_id,
        }

        request = call.StatusNotification(
            timestamp=request_payload["timestamp"],
            connector_status=connector_status,
            evse_id=evse_id,
            connector_id=request_payload["connectorId"],
        )
        response: call_result.StatusNotification = await self.call(request)
        return request_payload, normalize_response_payload(response)

    async def send_transaction_event_started(
        self, evse_id: int, connector_id: int, id_tag: str
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        self.current_transaction_id = f"tx-{uuid.uuid4().hex[:8]}"
        self.transaction_seq_no = 1
        request_payload = {
            "eventType": "Started",
            "timestamp": format_utc_z(),
            "triggerReason": "RemoteStart",
            "seqNo": self.transaction_seq_no,
            "transactionInfo": {
                "transactionId": self.current_transaction_id,
                "chargingState": "Charging",
            },
            "evse": {"id": evse_id, "connectorId": connector_id},
            "idToken": {"idToken": id_tag, "type": "Central"},
        }
        request = call.TransactionEvent(
            event_type=enums.TransactionEventEnumType.started,
            timestamp=request_payload["timestamp"],
            trigger_reason=enums.TriggerReasonEnumType.remote_start,
            seq_no=self.transaction_seq_no,
            transaction_info=datatypes.TransactionType(
                transaction_id=self.current_transaction_id,
                charging_state=enums.ChargingStateEnumType.charging,
            ),
            evse=datatypes.EVSEType(id=evse_id, connector_id=connector_id),
            id_token=datatypes.IdTokenType(
                id_token=id_tag, type=enums.IdTokenEnumType.central
            ),
        )
        response: call_result.TransactionEvent = await self.call(request)
        response_payload = normalize_response_payload(response)
        return request_payload, response_payload

    async def send_meter_values(self, evse_id: int) -> tuple[dict[str, Any], dict[str, Any]]:
        self.current_meter_wh += random.randint(20, 120)
        timestamp = format_utc_z()
        meter_value = datatypes.MeterValueType(
            timestamp=timestamp,
            sampled_value=[
                datatypes.SampledValueType(
                    value=float(self.current_meter_wh),
                    context=enums.ReadingContextEnumType.sample_periodic,
                    measurand=enums.MeasurandEnumType.energy_active_import_register,
                    unit_of_measure=datatypes.UnitOfMeasureType(unit="Wh"),
                )
            ],
        )
        request = call.MeterValues(
            evse_id=evse_id,
            meter_value=[meter_value],
        )
        response: call_result.MeterValues = await self.call(request)
        request_payload = {
            "evseId": evse_id,
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

    async def send_transaction_event_ended(
        self, evse_id: int, connector_id: int
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        stop_wh = self.current_meter_wh + random.randint(1, 30)
        self.transaction_seq_no += 1
        request_payload = {
            "eventType": "Ended",
            "timestamp": format_utc_z(),
            "triggerReason": "EVDeparted",
            "seqNo": self.transaction_seq_no,
            "transactionInfo": {
                "transactionId": self.current_transaction_id,
                "stoppedReason": "EVDisconnected",
                "chargingState": "Idle",
            },
            "evse": {"id": evse_id, "connectorId": connector_id},
            "meterValue": [
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
            ],
        }
        request = call.TransactionEvent(
            event_type=enums.TransactionEventEnumType.ended,
            timestamp=request_payload["timestamp"],
            trigger_reason=enums.TriggerReasonEnumType.ev_departed,
            seq_no=self.transaction_seq_no,
            transaction_info=datatypes.TransactionType(
                transaction_id=str(self.current_transaction_id),
                charging_state=enums.ChargingStateEnumType.idle,
                stopped_reason=enums.ReasonEnumType.ev_disconnected,
            ),
            meter_value=[
                datatypes.MeterValueType(
                    timestamp=request_payload["meterValue"][0]["timestamp"],
                    sampled_value=[
                        datatypes.SampledValueType(
                            value=float(stop_wh),
                            context=enums.ReadingContextEnumType.transaction_end,
                            measurand=enums.MeasurandEnumType.energy_active_import_register,
                            unit_of_measure=datatypes.UnitOfMeasureType(unit="Wh"),
                        )
                    ],
                )
            ],
            evse=datatypes.EVSEType(id=evse_id, connector_id=connector_id),
        )
        response: call_result.TransactionEvent = await self.call(request)
        return request_payload, normalize_response_payload(response)

    async def send_repeated_actions(
        self,
        loops: int,
        interval_s: float,
        evse_id: int,
        connector_id: int,
        log_writer: "SessionLogWriter",
        status_every: int,
        fault_probability: float,
    ) -> None:
        for index in range(1, loops + 1):
            if status_every > 0 and index % status_every == 0:
                preparing_req, preparing_res = await self.send_status_notification(
                    evse_id=evse_id, connector_id=connector_id, status="Preparing"
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=preparing_req,
                    response_payload=preparing_res,
                    msg_prefix="notif",
                )
                charging_req, charging_res = await self.send_status_notification(
                    evse_id=evse_id, connector_id=connector_id, status="Charging"
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
                    evse_id=evse_id,
                    connector_id=connector_id,
                    status="Faulted",
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=fault_req,
                    response_payload=fault_res,
                    msg_prefix="notif",
                )
                recover_req, recover_res = await self.send_status_notification(
                    evse_id=evse_id, connector_id=connector_id, status="Available"
                )
                log_writer.log_exchange(
                    charge_point_id=self.charge_point_id,
                    action="StatusNotification",
                    request_payload=recover_req,
                    response_payload=recover_res,
                    msg_prefix="notif",
                )
                resume_req, resume_res = await self.send_status_notification(
                    evse_id=evse_id, connector_id=connector_id, status="Charging"
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
            meter_req, meter_res = await self.send_meter_values(evse_id)
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

        for evse_id, connector_id in connector_ids:
            sn_req, sn_res = await charge_point.send_status_notification(
                evse_id=evse_id, connector_id=connector_id, status="Available"
            )
            log_writer.log_exchange(
                charge_point_id=charge_point_id,
                action="StatusNotification",
                request_payload=sn_req,
                response_payload=sn_res,
                msg_prefix="notif",
            )

        evse_id, connector_id = connector_ids[0]
        start_req, start_res = await charge_point.send_transaction_event_started(
            evse_id=evse_id,
            connector_id=connector_id,
            id_tag=f"ABC{random.randint(100, 999)}XYZ",
        )
        log_writer.log_exchange(
            charge_point_id=charge_point_id,
            action="TransactionEvent",
            request_payload=start_req,
            response_payload=start_res,
            msg_prefix="tx",
        )

        charging_req, charging_res = await charge_point.send_status_notification(
            evse_id=evse_id, connector_id=connector_id, status="Charging"
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
            evse_id=evse_id,
            connector_id=connector_id,
            log_writer=log_writer,
            status_every=status_every,
            fault_probability=fault_probability,
        )

        stop_req, stop_res = await charge_point.send_transaction_event_ended(
            evse_id=evse_id, connector_id=connector_id
        )
        log_writer.log_exchange(
            charge_point_id=charge_point_id,
            action="TransactionEvent",
            request_payload=stop_req,
            response_payload=stop_res,
            msg_prefix="stop",
        )

        final_req, final_res = await charge_point.send_status_notification(
            evse_id=evse_id, connector_id=connector_id, status="Available"
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
