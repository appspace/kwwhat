# auth_list.py
"""The idTag statuses the central system answers with, read from an auth list CSV.

Every row gives one idTag a status from `from_ts` on (always, when blank). The row with the latest
`from_ts` not after the time asked about applies, and an idTag without one is Accepted.
"""
import csv
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

AUTHORIZATION_STATUSES = ("Accepted", "Blocked", "Expired", "Invalid", "ConcurrentTx")
ALWAYS = datetime.min.replace(tzinfo=timezone.utc)


@dataclass(frozen=True)
class TokenStatus:
    status: str
    from_ts: datetime
    expiry_date: str | None = None


class AuthList:
    def __init__(self, statuses: dict[str, list[TokenStatus]] | None = None):
        self.statuses = {
            id_tag: sorted(rows, key=lambda row: row.from_ts) for id_tag, rows in (statuses or {}).items()
        }

    @classmethod
    def read(cls, path: Path) -> "AuthList":
        """Read an auth list CSV with the columns id_tag, status and optionally from_ts and expiry_date."""
        statuses: dict[str, list[TokenStatus]] = {}
        with path.open("r", encoding="utf-8", newline="") as file:
            for line, row in enumerate(csv.DictReader(file), start=2):
                id_tag, status = (row.get("id_tag") or "").strip(), (row.get("status") or "").strip()
                if status not in AUTHORIZATION_STATUSES:
                    raise SystemExit(f"{path}:{line}: status {status!r} is not one of {', '.join(AUTHORIZATION_STATUSES)}.")
                from_raw = (row.get("from_ts") or "").strip()
                statuses.setdefault(id_tag, []).append(
                    TokenStatus(
                        status=status,
                        from_ts=parse_timestamp(from_raw) if from_raw else ALWAYS,
                        expiry_date=(row.get("expiry_date") or "").strip() or None,
                    )
                )
        return cls(statuses)

    def id_tag_info(self, id_tag: str, at: datetime | None) -> dict[str, Any]:
        """The idTagInfo for `id_tag` at simulated time `at` (None: before any timestamp was seen)."""
        current = _status_at(self.statuses.get(id_tag, []), at or ALWAYS)
        if current is None:
            return {"status": "Accepted"}
        info: dict[str, Any] = {"status": current.status}
        if current.expiry_date:
            info["expiry_date"] = current.expiry_date
        return info


def _status_at(rows: list[TokenStatus], at: datetime) -> TokenStatus | None:
    applying = [row for row in rows if row.from_ts <= at]
    return applying[-1] if applying else None


def parse_timestamp(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
