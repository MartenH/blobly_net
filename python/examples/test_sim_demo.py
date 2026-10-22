"""A pytest suite against sim-demo's simulated ECUs, on blobly's plugin.

    pip install pytest
    pytest python/examples/test_sim_demo.py
    pytest python/examples/test_sim_demo.py --blobly-project=path/to/your.blobnet

conftest.py beside this file loads the plugin and pytest.ini names the project; a suite of your
own needs the same two lines. The plugin gives each test the started project (`project`), a
fixture per channel, named after it (`can1`), and a UDS client (`diag`), on the channel a test names
by parametrizing it: over CAN and over DoIP below. A test hears what arrives from its start, and
what it registers on the project or arms is dropped after it."""
import pytest


def test_the_project_has_its_channels(project):
    assert {ch.name: ch.kind for ch in project.channels} == {"CAN1": "can", "CAN2": "can", "DoIP1": "doip"}


def test_the_sut_answers_a_request(can1):
    can1.send(0x101, b"\x05")
    assert can1.expect(0x102, timeout_ms=500).data[0] == 6


def test_the_sut_answers_a_request_message(can1):
    can1.messages.Request.send(ReqCode=5)
    can1.expect_signal("Response", "RespCode", 6, timeout_ms=500)


@pytest.mark.parametrize("diag", ["CAN1", "DoIP1"], indirect=True)
def test_the_sut_reports_its_vin(diag):
    assert diag.read_did(0xF190) == b"BLOBLYNETV0SUT001"


def test_the_doip_entity_announces_the_vin_it_serves(doip1):
    assert doip1.discover().vin == "BLOBLYNETV0SUT001"


def test_the_sut_holds_its_two_dtcs(diag):
    assert [d.name for d in diag.supported_dtcs()] == ["P1234-56", "B2BCD-EF"]


def test_only_one_dtc_is_failing(diag):
    assert [d.name for d in diag.dtcs(0x01)] == ["P1234-56"]
    assert diag.dtc_count(0x01) == 1


def test_the_gear_steps_each_second(can1):
    _, gear = can1.expect_signal("Powertrain", "Gear", lambda g: 1 <= g <= 6, timeout_ms=500)
    _, after = can1.expect_signal("Powertrain", "Gear", lambda g: g != gear, timeout_ms=1500)
    assert after == gear % 6 + 1


def test_powertrain_stays_in_its_dbc_range(can1):
    pt = can1.messages.Powertrain
    for name, value in can1.decode(can1.expect(pt, timeout_ms=500)).items():
        assert pt.signals[name].minimum <= value <= pt.signals[name].maximum, name


def test_body_status_comes_on_can2(can2):
    assert can2.expect(can2.messages.BodyStatus, timeout_ms=1000)


@pytest.mark.parametrize("rpm", [0, 1500, 16383.75])
def test_engine_speed_encodes_and_decodes(can1, rpm):
    assert can1.decode(can1.messages.Powertrain.encode(EngineSpeed=rpm))["EngineSpeed"] == rpm


def test_requests_are_answered_during_run(project, can1):
    answers = []
    project.on_message(can1, can1.messages.Response, answers.append)
    project.on_timer(50, lambda: can1.messages.Request.send(ReqCode=5))
    project.run(500)
    assert len(answers) >= 3
