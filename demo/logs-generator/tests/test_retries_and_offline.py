"""Drivers who plug in again after a failed attempt, and periods in which the charger has no connection."""
from datetime import timedelta

import pytest

import common
from conftest import START, port_of, replay_ports, transactions

BUSY = ["--sessions-per-port-per-day", "20"]
RETRY = ["--retry-probability", "1"]
OFFLINE_FROM = "2025-11-01T10:00:00Z"
OFFLINE_TO = "2025-11-01T16:00:00Z"
OFFLINE = ["--offline", f"{OFFLINE_FROM}/{OFFLINE_TO}"]


def plug_ins(log, seeds):
    """Every driver at a port, as (port, connector, started_at, ended_at, transaction or None)."""
    ports = port_of(seeds, "CH-T1")
    visits, _, _ = replay_ports(log, ports)
    started = {tx["start"].payload["connectorId"]: [] for tx in transactions(log).values()}
    for tx in transactions(log).values():
        started[tx["start"].payload["connectorId"]].append(tx)
    result = []
    for visit in visits:
        tx = next(
            (tx for tx in started.get(visit.connector_id, []) if visit.started_at <= tx["start"].timestamp <= visit.ended_at),
            None,
        )
        result.append((visit.port_id, visit.connector_id, visit.started_at, visit.ended_at, tx))
    return sorted(result, key=lambda plug_in: plug_in[2])


def next_on_port(plug_in_list, index):
    port = plug_in_list[index][0]
    return next((later for later in plug_in_list[index + 1 :] if later[0] == port), None)


def test_a_failed_plug_in_is_retried_on_the_same_port_within_two_minutes(generate, seeds):
    log = generate(
        "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "3",
        *BUSY, *RETRY, "--failed-attempt-probability", "0.5", "--fault-probability", "0",
    )
    end = common.parse_timestamp(START) + timedelta(days=2)

    plug_in_list = plug_ins(log, seeds)
    # A retry near the end of the run may not fit, so only failed plug-ins well before it are checked.
    failed = [index for index, (_, _, _, ended_at, tx) in enumerate(plug_in_list) if tx is None and ended_at < end - timedelta(hours=4)]
    assert failed
    for index in failed:
        retry = next_on_port(plug_in_list, index)
        assert retry is not None and timedelta(seconds=10) <= retry[2] - plug_in_list[index][3] <= timedelta(seconds=90)
        # The retry charges: dbt joins the anonymous failed attempt to its driver's visit within 2 minutes.
        assert retry[4] is not None


def test_a_faulted_session_is_retried_once_by_the_same_driver_on_another_connector(generate, seeds):
    log = generate(
        "--charge-point-id", "CH-T1", "--start", START, "--days", "3", "--seed", "5",
        *BUSY, *RETRY, "--failed-attempt-probability", "0", "--fault-probability", "1",
    )

    plug_in_list = plug_ins(log, seeds)
    retried, retries = set(), set()
    for index, (_, connector, _, ended_at, tx) in enumerate(plug_in_list):
        later = next_on_port(plug_in_list, index)
        if later is None or later[2] - ended_at > timedelta(seconds=150):
            continue
        assert later[1] != connector, "the retry used the faulted connector"
        assert later[4]["start"].payload["idTag"] == tx["start"].payload["idTag"]
        retried.add(plug_in_list[index][2])
        retries.add(later[2])
    assert retried
    # Every retry faults too here, and a driver retries only once, so no retry is retried.
    assert not retried & retries


def test_without_retries_the_log_is_unchanged(generate, server, tmp_path):
    options = ["--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "7", "--fault-probability", "0.5"]
    without = generate(*options, "--output", str(tmp_path / "without.csv"))
    server.restart()
    zero = generate(*options, "--retry-probability", "0", "--output", str(tmp_path / "zero.csv"))

    assert without.path.read_bytes() == zero.path.read_bytes()


def test_an_offline_window_silences_the_charger_and_leaves_every_port_free(generate, seeds):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "1", "--seed", "1", *BUSY, *OFFLINE)
    offline_from, offline_to = common.parse_timestamp(OFFLINE_FROM), common.parse_timestamp(OFFLINE_TO)

    assert not [row for row in log.requests() if offline_from <= row.timestamp < offline_to]
    before = max(row.timestamp for row in log.requests() if row.timestamp < offline_from)
    after = min(row.timestamp for row in log.requests() if row.timestamp >= offline_to)
    assert after == offline_to and log.requests("Heartbeat")[0].timestamp < offline_from
    assert any(row.action == "Heartbeat" and row.timestamp == offline_to for row in log.requests())
    # dbt counts a gap longer than the heartbeat interval as an offline outage.
    assert after - before > timedelta(seconds=300)
    for port, _, started_at, ended_at, _ in plug_ins(log, seeds):
        assert ended_at <= offline_from or started_at >= offline_to, f"a driver was on port {port} across the window"


def test_an_offline_window_across_appended_runs_stays_silent(generate, seeds):
    window = ["--offline", "2025-11-01T20:00:00Z/2025-11-02T06:00:00Z"]
    generate("--append", "--charge-point-id", "CH-T1", "--start", START, "--days", "1", "--seed", "1", *BUSY, *window)
    log = generate("--append", "--charge-point-id", "CH-T1", "--days", "1", "--seed", "2", *BUSY, *window)

    offline_from, offline_to = (common.parse_timestamp(ts) for ts in window[1].split("/"))
    assert not [row for row in log.requests() if offline_from <= row.timestamp < offline_to]
    assert any(row.action == "Heartbeat" and row.timestamp == offline_to for row in log.requests())
    replay_ports(log, port_of(seeds, "CH-T1"))


@pytest.mark.parametrize("window", ["2025-11-01T16:00:00Z/2025-11-01T10:00:00Z", "yesterday/today"])
def test_an_invalid_offline_window_is_refused(generate, window):
    with pytest.raises(SystemExit):
        generate("--charge-point-id", "CH-T1", "--start", START, "--offline", window)
