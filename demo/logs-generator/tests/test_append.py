"""--append continues a series in the output file as if it were one long run."""
from datetime import timedelta

import pytest

import common
from conftest import START, port_of, replay_ports, transactions

BUSY_AND_FAULTY = ["--sessions-per-port-per-day", "20", "--fault-probability", "0.5"]


def snapshot(path):
    """Bytes of an output file and its state file, to check that a run left both unchanged."""
    state = common.append_state_path(path)
    return path.read_bytes(), state.read_bytes() if state.exists() else None


def test_two_appended_runs_continue_one_series(generate, server, seeds):
    first = generate("--append", "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", *BUSY_AND_FAULTY)
    first_end = common.parse_timestamp(START) + timedelta(days=2)
    # Every port is free and every connector Available at the end of an appended run.
    _, _, last_status = replay_ports(first, port_of(seeds, "CH-T1"))
    assert set(last_status.values()) == {"Available"}
    assert max(row.timestamp for row in first.rows) < first_end

    # The server is restarted between runs, so its transaction ids start at 5001 again.
    server.restart()
    log = generate("--append", "--charge-point-id", "CH-T1", "--days", "2", "--seed", "2", *BUSY_AND_FAULTY)

    assert log.raw_rows[: len(first.raw_rows)] == first.raw_rows
    second_part = log.rows[len(first.rows):]
    assert second_part and min(row.timestamp for row in second_part) >= first_end
    assert [row.action for row in log.requests("BootNotification")] == ["BootNotification"]
    beats = [row.timestamp for row in log.requests("Heartbeat")]
    assert {b - a for a, b in zip(beats, beats[1:])} == {timedelta(seconds=300)}
    requests = log.requests()
    assert len({row.message_id for row in requests}) == len(requests)
    # The whole series replays as one: no reboot statuses, no impossible status at the boundary.
    replay_ports(log, port_of(seeds, "CH-T1"))
    by_id = transactions(log)
    assert all("start" in tx and "stop" in tx for tx in by_id.values())
    ids_in_start_order = [tx_id for tx_id, tx in sorted(by_id.items(), key=lambda item: item[1]["start"].timestamp)]
    assert ids_in_start_order == sorted(ids_in_start_order)
    assert len(set(ids_in_start_order)) == len(ids_in_start_order)


def test_meters_continue_across_appended_runs(generate, server, seeds):
    ports = port_of(seeds, "CH-T1")
    first = generate("--append", "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1")
    # OCPP 1.6 StopTransaction has no connectorId, the port comes from the transaction's start.
    last_stop = {}
    for tx in sorted(transactions(first).values(), key=lambda tx: tx["stop"].timestamp):
        last_stop[ports[tx["start"].payload["connectorId"]]] = tx["stop"].payload["meterStop"]

    server.restart()
    log = generate("--append", "--charge-point-id", "CH-T1", "--days", "2", "--seed", "2")

    first_start = {}
    for row in log.requests("StartTransaction")[len(first.requests("StartTransaction")):]:
        first_start.setdefault(ports[row.payload["connectorId"]], row.payload["meterStart"])
    assert set(first_start) == set(last_stop) == {1, 2}
    for port in first_start:
        assert first_start[port] >= last_stop[port]


@pytest.mark.parametrize(
    "second_run, error",
    [
        (["--charge-point-id", "CH-T1", "--start", START], "--start cannot be used"),
        (["--charge-point-id", "CH-T2"], "is a series for CH-T1"),
        (["--charge-point-id", "CH-T1", "--ocpp-version", "2.0.1"], "is a series for CH-T1"),
    ],
)
def test_a_series_is_only_continued_by_the_same_charger_and_version(generate, second_run, error, tmp_path):
    generate("--append", "--charge-point-id", "CH-T1", "--start", START, "--seed", "1")
    before = snapshot(tmp_path / "out.csv")

    with pytest.raises(SystemExit, match=error):
        generate("--append", *second_run)
    assert snapshot(tmp_path / "out.csv") == before


def test_append_refuses_an_output_without_a_state_file(generate):
    generate("--charge-point-id", "CH-T1", "--start", START, "--seed", "1")

    with pytest.raises(SystemExit, match="is missing"):
        generate("--append", "--charge-point-id", "CH-T1")


def test_append_refuses_an_output_changed_since_the_last_run(generate, tmp_path):
    generate("--append", "--charge-point-id", "CH-T1", "--start", START, "--seed", "1")
    with (tmp_path / "out.csv").open("a", encoding="utf-8") as file:
        file.write("edited by hand\n")

    with pytest.raises(SystemExit, match="changed since the last run"):
        generate("--append", "--charge-point-id", "CH-T1")


def test_a_failed_appended_run_writes_nothing(generate, server, tmp_path):
    generate("--append", "--charge-point-id", "CH-T1", "--start", START, "--seed", "1")
    before = snapshot(tmp_path / "out.csv")

    server.refuse = True
    with pytest.raises(ConnectionRefusedError):
        generate("--append", "--charge-point-id", "CH-T1", "--seed", "2")
    assert snapshot(tmp_path / "out.csv") == before

    # A rerun once the server is back continues the series.
    server.refuse = False
    log = generate("--append", "--charge-point-id", "CH-T1", "--seed", "2")
    after = log.path.read_bytes()
    assert after.startswith(before[0]) and len(after) > len(before[0])


def test_append_after_decommissioning_generates_nothing(generate, tmp_path, capsys):
    # CH-OLD is decommissioned 2025-11-02T12:00, so the first run already reaches the end.
    generate("--append", "--charge-point-id", "CH-OLD", "--start", START, "--days", "3", "--seed", "1")
    before = snapshot(tmp_path / "out.csv")
    capsys.readouterr()

    generate("--append", "--charge-point-id", "CH-OLD", "--days", "3", "--seed", "2")

    assert snapshot(tmp_path / "out.csv") == before
    assert "not in commission" in capsys.readouterr().out
