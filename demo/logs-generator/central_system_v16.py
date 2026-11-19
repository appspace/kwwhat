# central_system_v16.py
import itertools

from datetime import datetime, timezone

from ocpp.routing import on
from ocpp.v16 import ChargePoint as cp
from ocpp.v16 import call_result
from ocpp.v16.enums import Action, RegistrationStatus

from auth_list import AuthList, parse_timestamp


class MyChargePoint(cp):
    _transaction_id_counter = itertools.count(5001)
    auth_list = AuthList()

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # The central system has no simulated clock of its own. It keeps the latest timestamp the
        # charger sent, which is how it answers Authorize (that carries no timestamp) in time.
        self.simulated_now: datetime | None = None

    def _observe(self, timestamp: str | None) -> datetime | None:
        if timestamp:
            seen = parse_timestamp(timestamp)
            self.simulated_now = max(self.simulated_now or seen, seen)
        return self.simulated_now

    @on(Action.boot_notification)
    async def on_boot_notification(
        self, charge_point_vendor, charge_point_model, **kwargs
    ):
        return call_result.BootNotification(
            current_time=datetime.now(tz=timezone.utc).isoformat(),
            interval=10,
            status=RegistrationStatus.accepted,
        )

    @on(Action.heartbeat)
    async def on_heartbeat(self, **kwargs):
        return call_result.Heartbeat(
            current_time=datetime.now(tz=timezone.utc).isoformat()
        )

    @on(Action.authorize)
    async def on_authorize(self, id_tag, **kwargs):
        return call_result.Authorize(id_tag_info=self.auth_list.id_tag_info(id_tag, self.simulated_now))

    @on(Action.meter_values)
    async def on_meter_values(self, **kwargs):
        return call_result.MeterValues()

    @on(Action.status_notification)
    async def on_status_notification(self, timestamp=None, **kwargs):
        self._observe(timestamp)
        return call_result.StatusNotification()

    @on(Action.start_transaction)
    async def on_start_transaction(self, id_tag, timestamp, **kwargs):
        return call_result.StartTransaction(
            transaction_id=next(self._transaction_id_counter),
            id_tag_info=self.auth_list.id_tag_info(id_tag, self._observe(timestamp)),
        )

    @on(Action.stop_transaction)
    async def on_stop_transaction(self, timestamp, **kwargs):
        self._observe(timestamp)
        return call_result.StopTransaction(id_tag_info={"status": "Accepted"})
