# central_system_v201.py

from datetime import datetime, timezone

from ocpp.routing import on
from ocpp.v201 import ChargePoint as cp
from ocpp.v201 import call_result
from ocpp.v201.enums import Action, RegistrationStatusEnumType


class MyChargePoint(cp):
    @on(Action.boot_notification)
    async def on_boot_notification(self, **kwargs):
        return call_result.BootNotification(
            current_time=datetime.now(tz=timezone.utc).isoformat(),
            interval=10,
            status=RegistrationStatusEnumType.accepted,
        )

    @on(Action.heartbeat)
    async def on_heartbeat(self, **kwargs):
        return call_result.Heartbeat(
            current_time=datetime.now(tz=timezone.utc).isoformat()
        )

    @on(Action.meter_values)
    async def on_meter_values(self, **kwargs):
        return call_result.MeterValues()

    @on(Action.status_notification)
    async def on_status_notification(self, **kwargs):
        return call_result.StatusNotification()

    @on(Action.transaction_event)
    async def on_transaction_event(self, **kwargs):
        return call_result.TransactionEvent()
