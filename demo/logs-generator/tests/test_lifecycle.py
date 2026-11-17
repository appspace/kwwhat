"""Traffic stays inside the charger's commissioned period from --chargers-file."""
import common
from conftest import START, port_of, replay_ports, transactions

BUSY_AND_FAULTY = ["--sessions-per-port-per-day", "20", "--fault-probability", "0.5"]


def test_a_run_starting_before_commissioning_boots_at_the_commissioning_time(generate):
    # CH-NEW is commissioned 2025-11-02T08:00, a day after START.
    log = generate("--charge-point-id", "CH-NEW", "--start", START, "--days", "3", "--seed", "1")

    commissioned_ts = common.parse_timestamp("2025-11-02T08:00:00Z")
    assert log.rows[0].action == "BootNotification"
    assert log.rows[0].timestamp == commissioned_ts
    assert min(row.timestamp for row in log.rows) == commissioned_ts


def test_nothing_is_sent_after_decommissioning_and_no_session_is_left_open(generate, seeds):
    # CH-OLD is decommissioned 2025-11-02T12:00, inside the requested period.
    log = generate("--charge-point-id", "CH-OLD", "--start", START, "--days", "3", "--seed", "1", *BUSY_AND_FAULTY)

    decommissioned_ts = common.parse_timestamp("2025-11-02T12:00:00Z")
    assert max(row.timestamp for row in log.rows) < decommissioned_ts
    assert all("stop" in tx for tx in transactions(log).values())
    _, repairs, last_status = replay_ports(log, port_of(seeds, "CH-OLD"))
    assert repairs
    assert set(last_status.values()) == {"Available"}


def test_a_period_outside_the_commissioned_period_gives_only_the_header(generate, server, capsys):
    log = generate("--charge-point-id", "CH-OLD", "--start", "2025-11-05T00:00:00Z", "--days", "2")

    assert log.header == ["timestamp", "id", "action", "msg"]
    assert log.rows == []
    assert server.connections == 0
    assert "not in commission" in capsys.readouterr().out


def test_ignore_lifecycle_generates_outside_the_commissioned_period(generate):
    log = generate("--charge-point-id", "CH-OLD", "--start", "2025-11-05T00:00:00Z", "--days", "1", "--seed", "1", "--ignore-lifecycle")

    assert log.rows[0].action == "BootNotification"
    assert log.rows[0].timestamp == common.parse_timestamp("2025-11-05T00:00:00Z")


def test_a_charger_missing_from_the_seeds_has_no_limits_and_one_connector(generate):
    log = generate("--charge-point-id", "CH-NOREF", "--start", START, "--days", "1", "--seed", "1")

    assert log.rows[0].timestamp == common.parse_timestamp(START)
    assert {status.connector_id for status in log.statuses()} == {1}
