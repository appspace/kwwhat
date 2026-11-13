# client.py
import asyncio

import charge_point_v16
import charge_point_v201
from common import configure_logging, parse_args, run_client

PROTOCOLS = {
    "1.6": (charge_point_v16.ChargePoint, "ocpp1.6"),
    "2.0.1": (charge_point_v201.ChargePoint, "ocpp2.0.1"),
}


if __name__ == "__main__":
    args = parse_args()
    configure_logging()
    charge_point_class, subprotocol = PROTOCOLS[args.ocpp_version]
    asyncio.run(run_client(args, charge_point_class, subprotocol))
