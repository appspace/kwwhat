"""Drivers' idTags: a shared driver file, online Authorize, and rejections by the central system."""
import pytest

import common
from auth_list import AuthList
from conftest import START, port_of, replay_ports, transactions

BUSY = ["--sessions-per-port-per-day", "20", "--failed-attempt-probability", "0", "--fault-probability", "0"]
ID_TAGS_CSV = "id_tag\nTAG-OK-1\nTAG-OK-2\nTAG-BAD-1\nTAG-BAD-2\n"
REJECTED_FROM = "2025-11-02T00:00:00Z"


@pytest.fixture
def id_tags_file(tmp_path):
    path = tmp_path / "id_tags.csv"
    path.write_text(ID_TAGS_CSV, encoding="utf-8")
    return path


@pytest.fixture
def auth_list(server, tmp_path):
    """TAG-BAD-1 is Blocked throughout, TAG-BAD-2 is Accepted until REJECTED_FROM, then Expired."""
    path = tmp_path / "auth_list.csv"
    path.write_text(
        "id_tag,status,from_ts,expiry_date\n"
        "TAG-BAD-1,Blocked,,\n"
        f"TAG-BAD-2,Expired,{REJECTED_FROM},2025-11-01T23:59:59Z\n",
        encoding="utf-8",
    )
    server.restart(auth_list=path)
    return path


def status_of(log, request):
    return log.response_to(request).payload["idTagInfo"]["status"]


def test_without_options_drivers_are_not_authorized_online(generate):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", *BUSY)

    assert log.requests("Authorize") == []
    assert {status_of(log, start) for start in log.requests("StartTransaction")} == {"Accepted"}


def test_drivers_come_from_the_id_tags_file_on_every_charger(generate, id_tags_file, tmp_path):
    tags = set()
    for charge_point_id in ("CH-T1", "CH-T2"):
        log = generate(
            "--charge-point-id", charge_point_id, "--start", START, "--days", "2", "--seed", "1", *BUSY,
            "--id-tags-file", str(id_tags_file), "--output", str(tmp_path / f"{charge_point_id}.csv"),
        )
        tags |= {start.payload["idTag"] for start in log.requests("StartTransaction")}

    assert tags == {"TAG-OK-1", "TAG-OK-2", "TAG-BAD-1", "TAG-BAD-2"}


def test_online_authorization_comes_before_every_transaction(generate, id_tags_file):
    log = generate(
        "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", *BUSY,
        "--id-tags-file", str(id_tags_file), "--authorize-probability", "1",
    )

    authorizations = log.requests("Authorize")
    starts = log.requests("StartTransaction")
    assert len(authorizations) == len(starts) > 0
    for authorization, start in zip(authorizations, starts):
        assert authorization.payload["idTag"] == start.payload["idTag"]
        assert authorization.timestamp < start.timestamp
        assert authorization.message_id.startswith("CH-T1-auth-")


def test_a_rejected_authorize_starts_no_transaction(generate, seeds, id_tags_file, auth_list):
    log = generate(
        "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", *BUSY,
        "--id-tags-file", str(id_tags_file), "--authorize-probability", "1",
    )

    rejected = [a for a in log.requests("Authorize") if status_of(log, a) != "Accepted"]
    assert {a.payload["idTag"] for a in rejected} == {"TAG-BAD-1", "TAG-BAD-2"}
    assert "TAG-BAD-1" not in {start.payload["idTag"] for start in log.requests("StartTransaction")}
    assert all(status_of(log, start) == "Accepted" for start in log.requests("StartTransaction"))
    replay_ports(log, port_of(seeds, "CH-T1"))


def test_a_status_applies_from_its_from_ts(generate, id_tags_file, auth_list):
    log = generate(
        "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", *BUSY,
        "--id-tags-file", str(id_tags_file), "--authorize-probability", "1",
    )

    rejected_from = common.parse_timestamp(REJECTED_FROM)
    expiring = [a for a in log.requests("Authorize") if a.payload["idTag"] == "TAG-BAD-2"]
    assert {status_of(log, a) for a in expiring if a.timestamp < rejected_from} == {"Accepted"}
    after = [log.response_to(a).payload["idTagInfo"] for a in expiring if a.timestamp > rejected_from]
    assert after and all(info == {"status": "Expired", "expiryDate": "2025-11-01T23:59:59Z"} for info in after)


def test_a_rejection_in_start_transaction_stops_it_before_energy_flows(generate, seeds, id_tags_file, auth_list):
    log = generate(
        "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", *BUSY,
        "--id-tags-file", str(id_tags_file),
    )

    deauthorized = 0
    for transaction in transactions(log).values():
        start, stop = transaction["start"], transaction["stop"]
        if status_of(log, start) == "Accepted":
            assert stop.payload["reason"] == "EVDisconnected"
            continue
        deauthorized += 1
        assert start.payload["idTag"] in {"TAG-BAD-1", "TAG-BAD-2"}
        assert stop.payload["reason"] == "DeAuthorized"
        assert stop.payload["meterStop"] == start.payload["meterStart"]
        assert (stop.timestamp - start.timestamp).total_seconds() <= 3
    assert deauthorized > 0
    _, _, last_status = replay_ports(log, port_of(seeds, "CH-T1"))
    assert set(last_status.values()) == {"Available"}


def test_authorization_is_refused_for_ocpp_201(generate):
    with pytest.raises(SystemExit, match="OCPP 1.6 only"):
        generate("--ocpp-version", "2.0.1", "--charge-point-id", "CH-T1", "--start", START, "--authorize-probability", "1")


def test_an_unknown_status_in_the_auth_list_is_refused(tmp_path):
    path = tmp_path / "auth_list.csv"
    path.write_text("id_tag,status\nTAG-1,Rejected\n", encoding="utf-8")

    with pytest.raises(SystemExit, match="not one of"):
        AuthList.read(path)
