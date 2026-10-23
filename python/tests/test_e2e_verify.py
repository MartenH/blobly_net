"""E2E on what a script reads and sends, through the library: projects/e2e-demo.blobnet, whose DBC
declares AUTOSAR E2E Profile 1 on BrakeStatus (the simulated Chassis sends it) and BrakeCommand
(nothing simulated sends it). Every frame read carries its verdict (Frame.e2e), expect and
expect_signal raise E2eError for a failing one when asked to, and Message.send stamps the declared
counter and CRC. E2E and E2E_TAP are one in-process wire, so what is sent on E2E is judged on
E2E_TAP. A software bus times a frame by its reading, so the E2ETimeout is checked on vcan0, where
the kernel stamps it, when there is one."""
import copy
import os
import pickle
import sys
import time

import pytest

import blobly
from blobly import E2eError, E2eStatus, FaultKind, e2e
from conftest import REPO, write

pytestmark = pytest.mark.usefixtures("engine")

E2E_DEMO = os.path.join(REPO, "projects", "e2e-demo.blobnet")
BRAKE_STATUS, BRAKE_COMMAND, WHEEL_SPEED = 0x301, 0x302, 0x303
COMMAND_DATA_ID = 0x2201


def frames(ch, frame_id, n, within_ms=2000):
    """The next n frames of `frame_id` on `ch`, within within_ms."""
    out, end = [], time.monotonic() + within_ms / 1000
    while len(out) < n and (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        if f is not None and f.id == frame_id:
            out.append(f)
    return out


def settle(ch):
    """Reads BrakeStatus until a frame passes: after a fault, the first good frame's counter
    jumped past the ones the broken frames carried."""
    assert any(f.e2e == "ok" for f in frames(ch, BRAKE_STATUS, 20)), "no passing BrakeStatus"


def counter(f):
    """BrakeCommand's counter: byte 3's low nibble."""
    return f.data[3] & 0x0F


@pytest.fixture(scope="class")
def net(engine):
    net = blobly.Project(E2E_DEMO).start()
    yield net
    net.stop()


@pytest.fixture
def ch(net):
    yield net.channels.E2E
    net.clear_faults()


@pytest.fixture
def tap(net):
    t = net.channels.E2E_TAP
    t.recv(0)  # opened: it hears what is sent from here on
    return t


class TestReceive:
    def test_every_frame_read_carries_its_verdict(self, ch):
        settle(ch)
        got = frames(ch, BRAKE_STATUS, 10)
        assert len(got) == 10
        assert all(f.e2e is E2eStatus.OK and f.e2e == "ok" for f in got), [f.e2e for f in got]
        assert ch.expect(WHEEL_SPEED, 500).e2e is None  # no E2E on its message

    def test_expect_with_e2e_returns_a_passing_frame(self, ch):
        settle(ch)
        assert ch.expect(BRAKE_STATUS, 500, e2e=True).e2e == "ok"
        assert ch.expect(ch.messages.BrakeStatus, 500, e2e=True).e2e == "ok"
        f, v = ch.expect_signal("BrakeStatus", "BrakePressure", lambda v: v >= 0, 500, e2e=True)
        assert f.e2e == "ok" and v >= 0

    def test_expect_with_e2e_refuses_a_frame_with_none_to_check(self, ch):
        with pytest.raises(E2eError, match="has no E2E to check") as e:
            ch.expect(WHEEL_SPEED, 500, e2e=True)
        assert e.value.status is None and e.value.frame.id == WHEEL_SPEED
        assert e.value.code == -12 and isinstance(e.value, blobly.BloblyError)

    @pytest.mark.parametrize("kind, status, meaning", [
        (FaultKind.BAD_CRC, E2eStatus.BAD_CRC, "its CRC does not match its bytes"),
        (FaultKind.FREEZE_COUNTER, E2eStatus.REPEATED, "its counter repeated"),
    ])
    def test_a_broken_sender_fails_the_check(self, net, ch, kind, status, meaning):
        net.fault(ch, "Chassis", "BrakeStatus", kind)
        # frames queued before the fault landed pass; the first after it raises
        with pytest.raises(E2eError) as e:
            for _ in range(100):
                ch.expect(BRAKE_STATUS, 500, e2e=True)
        assert e.value.status is status, e.value
        assert e.value.frame.e2e is status and e.value.frame.id == BRAKE_STATUS
        assert f"failed its E2E check: {status.value} ({meaning}" in str(e.value)
        net.clear_faults()
        settle(ch)

    def test_expect_signal_with_e2e_raises_rather_than_waits_out(self, net, ch):
        net.fault(ch, "Chassis", "BrakeStatus", "bad_crc")
        with pytest.raises(E2eError) as e:
            ch.expect_signal("BrakeStatus", "BrakePressure", lambda v: False, 2000, e2e=True)
        assert e.value.status is E2eStatus.BAD_CRC

    def test_a_handler_gets_each_frame_with_its_verdict(self, net, ch):
        settle(ch)
        seen = []
        net.on_message(ch, ch.messages.BrakeStatus, lambda f: seen.append(f.e2e))
        try:
            end = time.monotonic() + 5
            while len(seen) < 5 and time.monotonic() < end:
                net.run(100)
        finally:
            net._forget()
        assert len(seen) >= 5 and set(seen) == {E2eStatus.OK}, seen


class TestSend:
    def test_send_by_name_stamps_the_declared_counter_and_crc(self, ch, tap):
        cmd = ch.messages.BrakeCommand
        sent = [cmd.send(Demand=100 * i) for i in range(4)]
        heard = frames(tap, BRAKE_COMMAND, 4)
        assert heard == sent
        first = counter(sent[0])
        for i, f in enumerate(heard):
            assert f.e2e is E2eStatus.OK
            assert counter(f) == (first + i) % 15
            assert f.data[2] == e2e.p01_crc(f.data, COMMAND_DATA_ID, 2, 3)
            assert sent[i].e2e is None  # a frame sent is not a frame received

    def test_the_counter_is_the_runs_not_the_handles(self, ch, tap):
        cmd = ch.messages.BrakeCommand
        before = cmd.send(Demand=1)
        ch.close()  # the next send opens another handle
        after = cmd.send(Demand=2)
        assert counter(after) == (counter(before) + 1) % 15
        assert [f.e2e for f in frames(tap, BRAKE_COMMAND, 2)] == ["ok", "ok"]

    def test_an_encoded_frame_goes_out_unstamped(self, ch, tap):
        f = ch.messages.BrakeCommand.encode(Demand=700)
        assert (f.data[2], counter(f)) == (0, 0)
        assert e2e.p01_crc(f.data, COMMAND_DATA_ID, 2, 3) != 0
        ch.send(f.id, f.data, ext=f.ext)
        assert tap.expect(BRAKE_COMMAND, 500).e2e is E2eStatus.BAD_CRC

    def test_a_message_with_no_declaration_is_sent_as_encoded(self, ch, tap):
        f = ch.messages.WheelSpeed.send(Speed=12.5)
        assert f == ch.messages.WheelSpeed.encode(Speed=12.5)


class TestFrame:
    def test_the_verdict_is_not_part_of_the_value(self):
        judged = blobly.Frame(0x301, b"\x01", e2e="bad_crc")
        assert judged.e2e is E2eStatus.BAD_CRC
        assert judged == blobly.Frame(0x301, b"\x01") and hash(judged) == hash(blobly.Frame(0x301, b"\x01"))
        for twin in (copy.copy(judged), pickle.loads(pickle.dumps(judged))):
            assert twin.e2e is E2eStatus.BAD_CRC
        assert blobly.Frame(0x301).e2e is None
        with pytest.raises(ValueError):
            blobly.Frame(0x301, e2e="fine")

    def test_the_statuses_are_the_engines_names(self):
        # blobly/sim/e2e_script_test.v pins Violation.name() to the same list
        assert [s.value for s in E2eStatus] == ["ok", "bad_crc", "repeated", "skipped", "truncated", "timeout"]


# BrakeCommand on two rows of vcan0, one to send on and one to hear it with the kernel's stamps
VCAN_DBC = """VERSION ""

BU_: Tester Chassis

BO_ 1762 VcanCommand: 4 Tester
 SG_ Demand : 0|16@1+ (1,0) [0|65535] "" Chassis
 SG_ CommandCrc : 16|8@1+ (1,0) [0|255] "" Chassis
 SG_ CommandCounter : 24|4@1+ (1,0) [0|15] "" Chassis

BA_DEF_ BO_ "E2EDataId" INT 0 65535;
BA_DEF_ BO_ "E2ETimeout" INT 0 65535;
BA_ "E2ECounterSignal" BO_ 1762 "CommandCounter";
BA_ "E2ECrcSignal" BO_ 1762 "CommandCrc";
BA_ "E2EProfile" BO_ 1762 "P01";
BA_ "E2EDataId" BO_ 1762 8705;
BA_ "E2ETimeout" BO_ 1762 100;
"""

VCAN = """project:
  name: e2e-vcan
  version: 8
channels:
  - name: TX
    type: can
    interface: vcan0
    databases: [vcan.dbc]
  - name: RX
    type: can
    interface: vcan0
    databases: [vcan.dbc]
"""


@pytest.mark.skipif(not (sys.platform.startswith("linux") and os.path.exists("/sys/class/net/vcan0")),
                    reason="needs vcan0 (scripts/setup_vcan.sh)")
class TestTimeoutOnVcan:
    def test_a_frame_later_than_the_e2e_timeout_is_a_timeout(self, tmp_path):
        write(tmp_path, "vcan.dbc", VCAN_DBC)
        with blobly.Project(write(tmp_path, "vcan.blobnet", VCAN)) as net:
            tx, rx = net.channels.TX, net.channels.RX
            rx.recv(0)
            cmd = tx.messages.VcanCommand
            cmd.send(Demand=1)
            cmd.send(Demand=2)
            time.sleep(0.15)  # past the 100 ms E2ETimeout
            cmd.send(Demand=3)
            cmd.send(Demand=4)
            got = [f.e2e for f in frames(rx, 0x6E2, 4)]
            assert got == ["ok", "ok", "timeout", "ok"], got
