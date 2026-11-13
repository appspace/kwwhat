# charge_point_v16.py
import random
from collections import defaultdict
from datetime import datetime
from typing import Any

import websockets

from common import (
    Fault,
    charger_identity,
    format_utc_z,
    normalize_response_payload,
)

from ocpp.v16 import ChargePoint as cp
from ocpp.v16 import call, call_result
from ocpp.v16.enums import RegistrationStatus


class ChargePoint(cp):
    start_action_name = "StartTransaction"
    stop_action_name = "StopTransaction"

    def __init__(self, charge_point_id: str, connection: websockets.ClientConnection):
        super().__init__(charge_point_id, connection)
        self.charge_point_id = charge_point_id
        # Per port state: each port has its own meter register and open transaction.
        self.transaction_ids: dict[int, int] = {}
        # Last transaction id written to the log. The server numbers transactions from 5001 on
        # every start, so when a series is continued the logged ids are shifted to keep increasing.
        self.last_transaction_id: int | None = None
        self.transaction_id_offset: int | None = None
        self.meter_wh: dict[int, int] = defaultdict(lambda: random.randint(2_300_000, 2_305_000))

    async def send_boot_notification(self):
        identity = charger_identity(self.charge_point_id)
        request_payload = {
            "chargePointVendor": identity.vendor,
            "chargePointModel": identity.model,
            "chargePointSerialNumber": identity.serial_number,
            "firmwareVersion": identity.firmware_version,
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
        self,
        port_id: int,
        connector_id: int,
        status: str,
        ts: datetime,
        fault: Fault | None = None,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        request_payload = {
            "connectorId": connector_id,
            "status": status,
            "errorCode": fault.error_code if fault else "NoError",
            "timestamp": format_utc_z(ts),
        }
        if fault:
            request_payload["info"] = "Synthetic connector issue"
            if fault.vendor_id and fault.vendor_error_code:
                request_payload["vendorId"] = fault.vendor_id
                request_payload["vendorErrorCode"] = fault.vendor_error_code

        request = call.StatusNotification(
            connector_id=request_payload["connectorId"],
            status=request_payload["status"],
            error_code=request_payload["errorCode"],
            timestamp=request_payload["timestamp"],
            info=request_payload.get("info"),
            vendor_id=request_payload.get("vendorId"),
            vendor_error_code=request_payload.get("vendorErrorCode"),
        )
        response: call_result.StatusNotification = await self.call(request)
        return request_payload, normalize_response_payload(response)

    async def send_start_transaction(
        self, port_id: int, connector_id: int, id_tag: str, ts: datetime
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        request_payload = {
            "connectorId": connector_id,
            "idTag": id_tag,
            "timestamp": format_utc_z(ts),
            "meterStart": self.meter_wh[port_id],
        }
        request = call.StartTransaction(
            connector_id=request_payload["connectorId"],
            id_tag=request_payload["idTag"],
            timestamp=request_payload["timestamp"],
            meter_start=request_payload["meterStart"],
        )
        response: call_result.StartTransaction = await self.call(request)
        response_payload = normalize_response_payload(response)
        server_transaction_id = int(response_payload["transactionId"])
        if self.transaction_id_offset is None:
            self.transaction_id_offset = max(0, (self.last_transaction_id or 0) + 1 - server_transaction_id)
        transaction_id = server_transaction_id + self.transaction_id_offset
        response_payload["transactionId"] = transaction_id
        self.last_transaction_id = max(self.last_transaction_id or 0, transaction_id)
        self.transaction_ids[port_id] = transaction_id
        return request_payload, response_payload

    async def send_meter_values(
        self, port_id: int, connector_id: int, delta_wh: float, ts: datetime
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        self.meter_wh[port_id] += round(delta_wh)
        timestamp = format_utc_z(ts)
        sampled_value = {
            "value": str(self.meter_wh[port_id]),
            "context": "Sample.Periodic",
            "measurand": "Energy.Active.Import.Register",
            "unit": "Wh",
        }
        request = call.MeterValues(
            connector_id=connector_id,
            transaction_id=self.transaction_ids[port_id],
            meter_value=[
                {
                    "timestamp": timestamp,
                    "sampled_value": [sampled_value],
                }
            ],
        )
        response: call_result.MeterValues = await self.call(request)
        request_payload = {
            "connectorId": connector_id,
            "transactionId": self.transaction_ids[port_id],
            "meterValue": [
                {
                    "timestamp": timestamp,
                    "sampledValue": [sampled_value],
                }
            ],
        }
        return request_payload, normalize_response_payload(response)

    async def send_stop_transaction(
        self, port_id: int, connector_id: int, ts: datetime, reason: str, delta_wh: float
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        self.meter_wh[port_id] += round(delta_wh)
        stop_wh = self.meter_wh[port_id]
        timestamp = format_utc_z(ts)
        transaction_data = [
            {
                "timestamp": timestamp,
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
            "transactionId": self.transaction_ids.pop(port_id),
            "meterStop": stop_wh,
            "timestamp": timestamp,
            "reason": reason,
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

