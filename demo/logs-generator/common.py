# common.py
"""Helpers shared by the OCPP 1.6 and 2.0.1 log generator clients."""
import csv
import json
import logging
import random
from collections import defaultdict
from dataclasses import asdict, is_dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


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


class SessionLogWriter:
    def __init__(
        self,
        output: Path,
        response_delay_ms: int = 40,
        response_delay_jitter_ms: int = 10,
    ):
        self.output = output
        self.response_delay_ms = max(0, response_delay_ms)
        self.response_delay_jitter_ms = max(0, response_delay_jitter_ms)
        self.message_counters: dict[str, int] = defaultdict(int)
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
        self.message_counters[msg_prefix] += 1
        msg_id = f"{msg_prefix}-{self.message_counters[msg_prefix]:05d}"
        request_dt = datetime.now(timezone.utc)
        response_dt = request_dt + timedelta(
            milliseconds=self.response_delay_ms
            + random.randint(0, self.response_delay_jitter_ms)
        )
        request_time = format_utc_z(request_dt)
        response_time = format_utc_z(response_dt)
        self._write_row(request_time, charge_point_id, action, [2, msg_id, action, request_payload])
        self._write_row(response_time, charge_point_id, "", [3, msg_id, response_payload])
