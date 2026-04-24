# server.py
import asyncio
import itertools

from datetime import datetime, timezone
import websockets

from ocpp.routing import on
from ocpp.v16 import ChargePoint as cp
from ocpp.v16 import call_result
from ocpp.v16.enums import Action, RegistrationStatus


class MyChargePoint(cp):
    _transaction_id_counter = itertools.count(5001)

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

    @on(Action.meter_values)
    async def on_meter_values(self, **kwargs):
        return call_result.MeterValues()

    @on(Action.status_notification)
    async def on_status_notification(self, **kwargs):
        return call_result.StatusNotification()

    @on(Action.start_transaction)
    async def on_start_transaction(self, id_tag, **kwargs):
        return call_result.StartTransaction(
            transaction_id=next(self._transaction_id_counter),
            id_tag_info={"status": "Accepted"},
        )

    @on(Action.stop_transaction)
    async def on_stop_transaction(self, **kwargs):
        return call_result.StopTransaction(id_tag_info={"status": "Accepted"})


async def on_connect(connection: websockets.ServerConnection):
    """
    For every new connection, create a new ChargePoint instance,
    and start listening for messages.
    """
    charge_point_id = connection.request.path.split("/")[-1]
    charge_point = MyChargePoint(charge_point_id, connection)

    await charge_point.start()

async def main():
    server = await websockets.serve(
        on_connect,
        '0.0.0.0',
        9000,
        subprotocols=["ocpp2.0.1"],
    )
    await server.wait_closed()

if __name__ == '__main__':
    asyncio.run(main())
