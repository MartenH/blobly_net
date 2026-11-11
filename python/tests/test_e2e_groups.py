"""E2E in several windows of one frame (#615): a DBC's E2E attributes at SG_ scope protect the
signal group holding the signal they sit on, each group its own CRC, counter and Data ID over the
bytes its members span. A frame read carries the worst verdict in Frame.e2e and each window's in
Frame.e2e_groups; a fault acts on every window or the one it names; Message.send stamps every
window."""
import time

import pytest

import blobly
from blobly import E2eStatus, FaultKind, e2e
from conftest import write

pytestmark = pytest.mark.usefixtures("engine")

DBC = """VERSION ""

BU_: Ecu Tester

BO_ 291 EngineData: 8 Ecu
 SG_ Speed_CRC : 0|8@1+ (1,0) [0|255] "" Tester
 SG_ Speed_Counter : 8|4@1+ (1,0) [0|15] "" Tester
 SG_ Speed : 16|16@1+ (1,0) [0|65535] "" Tester
 SG_ Torque_CRC : 32|8@1+ (1,0) [0|255] "" Tester
 SG_ Torque_Counter : 40|4@1+ (1,0) [0|15] "" Tester
 SG_ Torque : 48|16@1+ (1,0) [0|65535] "" Tester

BO_ 292 Command: 8 Tester
 SG_ A_CRC : 0|8@1+ (1,0) [0|255] "" Ecu
 SG_ A_Counter : 8|4@1+ (1,0) [0|15] "" Ecu
 SG_ B_CRC : 32|8@1+ (1,0) [0|255] "" Ecu
 SG_ B_Counter : 40|4@1+ (1,0) [0|15] "" Ecu

BA_DEF_ BO_ "GenMsgCycleTime" INT 0 65535;
BA_ "GenMsgCycleTime" BO_ 291 10;
BA_ "E2ECrcSignal" SG_ 291 Speed_CRC "Speed_CRC";
BA_ "E2ECounterSignal" SG_ 291 Speed_CRC "Speed_Counter";
BA_ "E2EProfile" SG_ 291 Speed_CRC "P01";
BA_ "E2EDataId" SG_ 291 Speed_CRC 68;
BA_ "E2ECrcSignal" SG_ 291 Torque_CRC "Torque_CRC";
BA_ "E2ECounterSignal" SG_ 291 Torque_CRC "Torque_Counter";
BA_ "E2EProfile" SG_ 291 Torque_CRC "P01";
BA_ "E2EDataId" SG_ 291 Torque_CRC 69;
BA_ "E2ECrcSignal" SG_ 292 A_CRC "A_CRC";
BA_ "E2ECounterSignal" SG_ 292 A_CRC "A_Counter";
BA_ "E2EProfile" SG_ 292 A_CRC "P01";
BA_ "E2EDataId" SG_ 292 A_CRC 16;
BA_ "E2ECrcSignal" SG_ 292 B_CRC "B_CRC";
BA_ "E2ECounterSignal" SG_ 292 B_CRC "B_Counter";
BA_ "E2EProfile" SG_ 292 B_CRC "P01";
BA_ "E2EDataId" SG_ 292 B_CRC 17;
SIG_GROUP_ 291 SpeedGroup 1 : Speed_CRC Speed_Counter Speed;
SIG_GROUP_ 291 TorqueGroup 1 : Torque_CRC Torque_Counter Torque;
SIG_GROUP_ 292 AGroup 1 : A_CRC A_Counter;
SIG_GROUP_ 292 BGroup 1 : B_CRC B_Counter;
"""

PROJECT = """project:
  name: e2e-groups
  version: 8
channels:
  - name: E2E
    type: can
    interface: inproc:PY_E2EG
    databases:
      - groups.dbc
    simulation:
      - name: Ecu
        signals:
          - { name: Speed, type: sawtooth, min: 0, max: 1000, period: 1 }
  - name: E2E_TAP
    type: can
    interface: inproc:PY_E2EG
    databases:
      - groups.dbc
"""
ENGINE = 291


@pytest.fixture(scope="module")
def net(tmp_path_factory):
    d = tmp_path_factory.mktemp("e2e_groups")
    write(d, "groups.dbc", DBC)
    net = blobly.Project(write(d, "groups.blobnet", PROJECT)).start()
    yield net
    net.stop()


@pytest.fixture
def ch(net):
    yield net.channels.E2E
    net.clear_faults()


def engine_frames(ch, n, within_ms=2000):
    out, end = [], time.monotonic() + within_ms / 1000
    while len(out) < n and (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        if f is not None and f.id == ENGINE:
            out.append(f)
    return out


def settled(ch, pred, n=40):
    return any(pred(f) for f in engine_frames(ch, n))


def test_each_window_carries_its_verdict(ch):
    assert settled(ch, lambda f: f.e2e is E2eStatus.OK)
    f = engine_frames(ch, 1)[0]
    assert f.e2e == "ok"
    assert f.e2e_groups == {"SpeedGroup": "ok", "TorqueGroup": "ok"}
    # each window is its own Profile 1 over its four bytes
    assert f.data[0] == e2e.p01_crc(f.data[:4], 68, 0, 1)
    assert f.data[4] == e2e.p01_crc(f.data[4:], 69, 0, 1)
    # not part of the frame's value
    assert f == blobly.Frame(f.id, f.data)


def test_a_fault_on_one_window_fails_that_window_only(net, ch):
    net.fault(ch, "Ecu", "EngineData", FaultKind.BAD_CRC, group="TorqueGroup")
    assert settled(ch, lambda f: f.e2e_groups == {"SpeedGroup": "ok", "TorqueGroup": "bad_crc"})
    f = engine_frames(ch, 1)[0]
    assert f.e2e == "bad_crc", "the frame reads the worst of its windows"


def test_a_fault_names_a_window_the_message_has(net, ch):
    with pytest.raises(blobly.FaultRefused, match='no E2E window "Nope"'):
        net.fault(ch, "Ecu", "EngineData", "bad_crc", group="Nope")
    with pytest.raises(ValueError, match="not both"):
        net.fault(ch, "Ecu", "EngineData", "bad_crc", signal="Speed", group="TorqueGroup")
    with pytest.raises(ValueError, match="bad_crc or freeze_counter"):
        net.fault(ch, "Ecu", "EngineData", "drop", group="TorqueGroup")


def test_send_stamps_every_window(net):
    tap = net.channels.E2E_TAP
    tap.recv(0)
    cmd = net.channels.E2E.messages.Command
    for _ in range(3):
        cmd.send()
        f = tap.expect(0x124, 500)
        assert f.e2e == "ok", f.e2e_groups
        assert f.e2e_groups == {"AGroup": "ok", "BGroup": "ok"}
