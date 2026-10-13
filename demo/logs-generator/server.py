# server.py
import asyncio

from datetime import datetime, timezone
import websockets

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


async def on_connect(connection: websockets.ServerConnection):
    """
    For every new connection, create a new ChargePoint instance,
    and start listening for messages.
    """
    charge_point_id = connection.request.path.split("/")[-1]
    charge_point = MyChargePoint(charge_point_id, connection)
    try:
        await charge_point.start()
    except websockets.exceptions.ConnectionClosedOK:
        # Normal shutdown when client closes after sending a finite test run.
        pass

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