# server.py
import asyncio

import websockets

import central_system_v16
import central_system_v201

# One central system serving both protocol versions. The client picks the version in the
# websocket handshake by offering "ocpp1.6" or "ocpp2.0.1" as its subprotocol. Clients that
# offer neither are rejected by websockets before on_connect runs.
CHARGE_POINT_CLASSES = {
    "ocpp1.6": central_system_v16.MyChargePoint,
    "ocpp2.0.1": central_system_v201.MyChargePoint,
}


async def on_connect(connection: websockets.ServerConnection):
    """
    For every new connection, create a ChargePoint instance for the negotiated
    OCPP version, and start listening for messages.
    """
    charge_point_class = CHARGE_POINT_CLASSES[connection.subprotocol]
    charge_point_id = connection.request.path.split("/")[-1]
    charge_point = charge_point_class(charge_point_id, connection)
    try:
        await charge_point.start()
    except websockets.exceptions.ConnectionClosedOK:
        # Normal shutdown when client closes after sending a finite test run.
        pass


async def main():
    server = await websockets.serve(
        on_connect,
        "0.0.0.0",
        9000,
        subprotocols=list(CHARGE_POINT_CLASSES),
    )
    await server.wait_closed()


if __name__ == "__main__":
    asyncio.run(main())
