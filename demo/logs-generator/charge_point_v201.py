# charge_point_v201.py
import random
import uuid
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

from ocpp.v201 import ChargePoint as cp
from ocpp.v201 import call, call_result, datatypes, enums


class ChargePoint(cp):
    start_action_name = "TransactionEvent"
    stop_action_name = "TransactionEvent"

    def __init__(self, charge_point_id: str, connection: websockets.ClientConnection):
        super().__init__(charge_point_id, connection)
        self.charge_point_id = charge_point_id
        # Per port (EVSE) state: each port has its own meter register and open transaction.
        self.transaction_ids: dict[int, str] = {}
        self.transaction_seq_nos: dict[int, int] = {}
        self.meter_wh: dict[int, int] = defaultdict(lambda: random.randint(2_300_000, 2_305_000))

    async def send_boot_notification(self):
        identity = charger_identity(self.charge_point_id)
        request_payload = {
            "chargingStation": {
                "vendorName": identity.vendor,
                "model": identity.model,
                "serialNumber": identity.serial_number,
                "firmwareVersion": identity.firmware_version,
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
        self,
        port_id: int,
        connector_id: int,
        status: str,
        ts: datetime,
        fault: Fault | None = None,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        # OCPP 2.0.1 StatusNotification has no error fields, so fault is ignored.
        connector_status_map = {
            "Available": enums.ConnectorStatusEnumType.available,
            "Preparing": enums.ConnectorStatusEnumType.occupied,
            "Charging": enums.ConnectorStatusEnumType.occupied,
            "Finishing": enums.ConnectorStatusEnumType.occupied,
            "Faulted": enums.ConnectorStatusEnumType.faulted,
        }
        connector_status = connector_status_map.get(
            status, enums.ConnectorStatusEnumType.occupied
        )
        request_payload = {
            "timestamp": format_utc_z(ts),
            "connectorStatus": connector_status.value,
            "evseId": port_id,
            "connectorId": connector_id,
        }

        request = call.StatusNotification(
            timestamp=request_payload["timestamp"],
            connector_status=connector_status,
            evse_id=port_id,
            connector_id=request_payload["connectorId"],
        )
        response: call_result.StatusNotification = await self.call(request)
        return request_payload, normalize_response_payload(response)

    async def send_start_transaction(
        self, port_id: int, connector_id: int, id_tag: str, ts: datetime
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        transaction_id = f"tx-{uuid.uuid4().hex[:8]}"
        self.transaction_ids[port_id] = transaction_id
        self.transaction_seq_nos[port_id] = 1
        request_payload = {
            "eventType": "Started",
            "timestamp": format_utc_z(ts),
            "triggerReason": "RemoteStart",
            "seqNo": self.transaction_seq_nos[port_id],
            "transactionInfo": {
                "transactionId": transaction_id,
                "chargingState": "Charging",
            },
            "evse": {"id": port_id, "connectorId": connector_id},
            "idToken": {"idToken": id_tag, "type": "Central"},
        }
        request = call.TransactionEvent(
            event_type=enums.TransactionEventEnumType.started,
            timestamp=request_payload["timestamp"],
            trigger_reason=enums.TriggerReasonEnumType.remote_start,
            seq_no=self.transaction_seq_nos[port_id],
            transaction_info=datatypes.TransactionType(
                transaction_id=transaction_id,
                charging_state=enums.ChargingStateEnumType.charging,
            ),
            evse=datatypes.EVSEType(id=port_id, connector_id=connector_id),
            id_token=datatypes.IdTokenType(
                id_token=id_tag, type=enums.IdTokenEnumType.central
            ),
        )
        response: call_result.TransactionEvent = await self.call(request)
        return request_payload, normalize_response_payload(response)

    async def send_meter_values(
        self, port_id: int, connector_id: int, delta_wh: float, ts: datetime
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        self.meter_wh[port_id] += round(delta_wh)
        timestamp = format_utc_z(ts)
        meter_value = datatypes.MeterValueType(
            timestamp=timestamp,
            sampled_value=[
                datatypes.SampledValueType(
                    value=float(self.meter_wh[port_id]),
                    context=enums.ReadingContextEnumType.sample_periodic,
                    measurand=enums.MeasurandEnumType.energy_active_import_register,
                    unit_of_measure=datatypes.UnitOfMeasureType(unit="Wh"),
                )
            ],
        )
        request = call.MeterValues(
            evse_id=port_id,
            meter_value=[meter_value],
        )
        response: call_result.MeterValues = await self.call(request)
        request_payload = {
            "evseId": port_id,
            "meterValue": [
                {
                    "timestamp": timestamp,
                    "sampledValue": [
                        {
                            "value": str(self.meter_wh[port_id]),
                            "context": "Sample.Periodic",
                            "measurand": "Energy.Active.Import.Register",
                            "unit": "Wh",
                        }
                    ],
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
        transaction_id = self.transaction_ids.pop(port_id)
        self.transaction_seq_nos[port_id] += 1
        seq_no = self.transaction_seq_nos.pop(port_id)
        if reason == "Other":
            trigger_reason = enums.TriggerReasonEnumType.abnormal_condition
            stopped_reason = enums.ReasonEnumType.other
        else:
            trigger_reason = enums.TriggerReasonEnumType.ev_departed
            stopped_reason = enums.ReasonEnumType.ev_disconnected
        request_payload = {
            "eventType": "Ended",
            "timestamp": timestamp,
            "triggerReason": trigger_reason.value,
            "seqNo": seq_no,
            "transactionInfo": {
                "transactionId": transaction_id,
                "stoppedReason": stopped_reason.value,
                "chargingState": "Idle",
            },
            "evse": {"id": port_id, "connectorId": connector_id},
            "meterValue": [
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
            ],
        }
        request = call.TransactionEvent(
            event_type=enums.TransactionEventEnumType.ended,
            timestamp=timestamp,
            trigger_reason=trigger_reason,
            seq_no=seq_no,
            transaction_info=datatypes.TransactionType(
                transaction_id=transaction_id,
                charging_state=enums.ChargingStateEnumType.idle,
                stopped_reason=stopped_reason,
            ),
            meter_value=[
                datatypes.MeterValueType(
                    timestamp=timestamp,
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
            evse=datatypes.EVSEType(id=port_id, connector_id=connector_id),
        )
        response: call_result.TransactionEvent = await self.call(request)
        return request_payload, normalize_response_payload(response)

