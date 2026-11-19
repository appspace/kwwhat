"""Invariants of one generated series: format, ports, faults, transactions, meters, heartbeats."""
from datetime import timedelta

import pytest

import common
from conftest import START, port_of, replay_ports, transactions

BUSY = ["--sessions-per-port-per-day", "20"]
FAULTY = ["--fault-probability", "0.5"]


@pytest.mark.parametrize("ocpp_version", ["1.6", "2.0.1"])
def test_output_is_sorted_and_every_request_has_one_response(generate, ocpp_version):
    log = generate("--ocpp-version", ocpp_version, "--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", *FAULTY)

    assert log.header == ["timestamp", "id", "action", "msg"]
    assert [row["timestamp"] for row in log.raw_rows] == sorted(row["timestamp"] for row in log.raw_rows)
    assert {row.charge_point_id for row in log.rows} == {"CH-T1"}
    requests, responses = log.requests(), log.responses()
    assert len(requests) == len(responses)
    assert len({row.message_id for row in requests}) == len(requests), "message ids repeat"
    responses_by_id = {row.message_id: row for row in responses}
    for request in requests:
        assert request.message_id.startswith("CH-T1-")
        assert len(request.message_id) <= common.MAX_MESSAGE_ID_LENGTH
        response = responses_by_id[request.message_id]
        assert response.action == ""
        assert response.timestamp > request.timestamp


def test_charge_point_id_too_long_for_message_ids_is_refused(generate):
    with pytest.raises(SystemExit, match="longer than"):
        generate("--charge-point-id", "C" * (common.MAX_CHARGE_POINT_ID_LENGTH + 1), "--start", START)


def test_same_seed_gives_the_same_log(generate, server, tmp_path):
    options = ["--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "7", *FAULTY]
    first = generate(*options, "--output", str(tmp_path / "first.csv"))
    server.restart()
    second = generate(*options, "--output", str(tmp_path / "second.csv"))

    assert first.path.read_bytes() == second.path.read_bytes()


def test_charger_identity_depends_only_on_the_charge_point_id(generate, tmp_path):
    boots = [
        generate("--charge-point-id", "CH-T1", "--start", START, "--seed", str(seed), "--output", str(tmp_path / f"{seed}.csv"))
        .requests("BootNotification")[0]
        .payload
        for seed in (1, 2)
    ]

    assert boots[0] == boots[1]
    identity = common.charger_identity("CH-T1")
    assert boots[0]["chargePointVendor"] == identity.vendor
    assert boots[0]["chargePointSerialNumber"] == identity.serial_number


def test_startup_boots_then_reports_every_connector_available(generate):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--seed", "1")

    assert log.rows[0].action == "BootNotification"
    assert log.rows[0].timestamp == common.parse_timestamp(START)
    first_statuses = log.statuses()[:4]
    assert [(s.connector_id, s.status) for s in first_statuses] == [(1, "Available"), (2, "Available"), (3, "Available"), (4, "Available")]


def test_heartbeats_are_evenly_spaced(generate):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "1", "--heartbeat-interval", "600", "--seed", "1")

    beats = [row.timestamp for row in log.requests("Heartbeat")]
    assert beats[0] == common.parse_timestamp(START) + timedelta(seconds=600)
    assert {b - a for a, b in zip(beats, beats[1:])} == {timedelta(seconds=600)}
    assert len(beats) == 24 * 6 - 1


def test_a_port_serves_one_driver_at_a_time(generate, seeds):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "5", "--seed", "3", *BUSY, *FAULTY)

    visits, _, _ = replay_ports(log, port_of(seeds, "CH-T1"))
    assert len(visits) > 50


def test_a_fault_takes_only_its_own_connector_out_of_service(generate, seeds):
    """While a connector is being repaired, drivers keep charging on the other connectors of its port."""
    ports = port_of(seeds, "CH-T1")
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "5", "--seed", "3", *BUSY, *FAULTY)

    visits, repairs, _ = replay_ports(log, ports)
    assert repairs, "the run should contain faults"
    visits_during_repair = [
        visit
        for connector, faulted_at, repaired_at in repairs
        for visit in visits
        if visit.port_id == ports[connector] and visit.connector_id != connector and faulted_at < visit.started_at < repaired_at
    ]
    assert visits_during_repair, "no driver used the other connector of a port while one connector was in repair"


def test_a_port_is_down_only_while_all_its_connectors_are_faulted(generate, seeds):
    ports = port_of(seeds, "CH-T1")
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "5", "--seed", "3", *BUSY, *FAULTY)

    visits, repairs, _ = replay_ports(log, ports)
    connectors_of_port = {port: {c for c, p in ports.items() if p == port} for port in set(ports.values())}
    in_repair = lambda connector, ts: any(c == connector and a < ts < b for c, a, b in repairs)  # noqa: E731
    for visit in visits:
        assert not in_repair(visit.connector_id, visit.started_at), f"{visit} started on a connector in repair"
        assert not all(in_repair(c, visit.started_at) for c in connectors_of_port[visit.port_id])


def test_a_single_connector_port_serves_nobody_during_its_repair(generate, seeds):
    log = generate("--charge-point-id", "CH-T2", "--start", START, "--days", "5", "--seed", "3", *BUSY, *FAULTY)

    visits, repairs, _ = replay_ports(log, port_of(seeds, "CH-T2"))
    assert repairs
    for _, faulted_at, repaired_at in repairs:
        assert not [v for v in visits if faulted_at < v.started_at < repaired_at]


def test_faults_end_the_session_and_report_error_codes(generate):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "3", "--seed", "5", *FAULTY, "--vendor-error-code-probability", "0.5")

    faulted = [s for s in log.statuses() if s.status == "Faulted"]
    assert faulted
    for status in faulted:
        assert status.payload["errorCode"] != "NoError"
        if "vendorErrorCode" in status.payload:
            assert status.payload["vendorId"] == "https://chargex.inl.gov"
            # CX016 has no OCPP 1.6 equivalent, so it is sent as OtherError.
            expected = {"CX002": "GroundFailure", "CX016": "OtherError"}[status.payload["vendorErrorCode"]]
            assert status.payload["errorCode"] == expected
        else:
            assert status.payload["errorCode"] in common.PLAIN_FAULT_ERROR_CODES
    assert any("vendorErrorCode" in s.payload for s in faulted)
    assert any("vendorErrorCode" not in s.payload for s in faulted)
    stops_other = [row for row in log.requests("StopTransaction") if row.payload["reason"] == "Other"]
    assert len(stops_other) == len(faulted)


def test_ocpp_201_faults_show_only_the_faulted_status(generate):
    log = generate("--ocpp-version", "2.0.1", "--charge-point-id", "CH-T1", "--start", START, "--days", "3", "--seed", "5", *FAULTY)

    faulted = [s for s in log.statuses() if s.status == "Faulted"]
    assert faulted
    assert all("errorCode" not in s.payload for s in faulted)


def test_failed_attempts_never_start_a_transaction(generate, seeds):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "2", "--seed", "1", "--failed-attempt-probability", "1")

    assert not log.requests("StartTransaction")
    visits, _, _ = replay_ports(log, port_of(seeds, "CH-T1"))
    assert visits
    assert all(timedelta(seconds=20) <= v.ended_at - v.started_at <= timedelta(seconds=120) for v in visits)


def test_no_sessions_when_the_arrival_rate_is_zero(generate):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "1", "--seed", "1", "--sessions-per-port-per-day", "0")

    assert {row.action for row in log.requests()} == {"BootNotification", "StatusNotification", "Heartbeat"}


def test_every_transaction_is_stopped_and_ids_increase_with_time(generate):
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "3", "--seed", "2", *BUSY, *FAULTY)

    by_id = transactions(log)
    assert by_id
    assert all("start" in tx and "stop" in tx for tx in by_id.values()), "a transaction was left open or never started"
    ids_in_start_order = [tx_id for tx_id, tx in sorted(by_id.items(), key=lambda item: item[1]["start"].timestamp)]
    assert ids_in_start_order == sorted(ids_in_start_order)
    assert ids_in_start_order[0] == 5001


def test_ocpp_201_every_transaction_is_ended(generate):
    log = generate("--ocpp-version", "2.0.1", "--charge-point-id", "CH-T1", "--start", START, "--days", "3", "--seed", "2", *FAULTY)

    events: dict[str, list[str]] = {}
    for row in log.requests("TransactionEvent"):
        events.setdefault(row.payload["transactionInfo"]["transactionId"], []).append(row.payload["eventType"])
    assert events
    for event_types in events.values():
        assert event_types[0] == "Started"
        assert event_types[-1] == "Ended"
        assert event_types.count("Ended") == 1


def test_meters_never_go_backwards(generate, seeds):
    ports = port_of(seeds, "CH-T1")
    log = generate("--charge-point-id", "CH-T1", "--start", START, "--days", "3", "--seed", "4", *BUSY)

    # Every reading of a port's meter register, as (timestamp, Wh). The log is in time order.
    readings: dict[int, list[tuple]] = {}
    for tx in transactions(log).values():
        port = ports[tx["start"].payload["connectorId"]]
        assert tx["stop"].payload["meterStop"] > tx["start"].payload["meterStart"]
        readings.setdefault(port, []).append((tx["start"].timestamp, tx["start"].payload["meterStart"]))
        readings[port].append((tx["stop"].timestamp, tx["stop"].payload["meterStop"]))
    for row in log.requests("MeterValues"):
        value = int(row.payload["meterValue"][0]["sampledValue"][0]["value"])
        readings[ports[row.payload["connectorId"]]].append((row.timestamp, value))
    assert len(readings) == 2
    for port, port_readings in readings.items():
        values = [wh for _, wh in sorted(port_readings)]
        assert all(a <= b for a, b in zip(values, values[1:])), f"meter of port {port} went backwards"
