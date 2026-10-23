"""Fault injection from Python, seen on the bus: projects/sim-demo.blobnet for drop and
out_of_range and for the refusals (it protects nothing, so bad_crc and freeze_counter are refused
there), and a project of one Profile 1 protected message for bad_crc and freeze_counter, checked
with blobly.e2e. Every fault is then cleared and the traffic seen to recover."""
import os
import re
import time

import pytest

import blobly
from blobly import FaultKind, FaultRefused, e2e
from conftest import SIM_DEMO

pytestmark = pytest.mark.usefixtures("engine")

POWERTRAIN, HEARTBEAT, BRAKE_STATUS = 0x100, 0x700, 0x301


# BrakeStatus as blobly_emb overspeed lays it out, protected with Profile 1 and sent every 10 ms
E2E_DBC = """VERSION ""

BU_: Chassis Tester

BO_ 769 BrakeStatus: 6 Chassis
 SG_ BrakePressure : 0|16@1+ (1,0) [0|65535] "" Tester
 SG_ Pad : 16|8@1+ (1,0) [0|255] "" Tester
 SG_ BrakeCrc : 32|8@1+ (1,0) [0|255] "" Tester
 SG_ BrakeCounter : 40|4@1+ (1,0) [0|15] "" Tester

BA_DEF_ BO_ "GenMsgCycleTime" INT 0 65535;
BA_ "GenMsgCycleTime" BO_ 769 10;
"""

E2E = """project:
  name: e2e
  version: 8
channels:
  - name: E2E
    type: can
    interface: inproc:PY_E2E
    databases:
      - e2e.dbc
    simulation:
      - name: Chassis
        signals:
          - { name: BrakePressure, type: sine, offset: 1000, amplitude: 500, freq: 1 }
        protect:
          - { message: BrakeStatus, counter: BrakeCounter, crc: BrakeCrc, profile: autosar_p01, data_id: 0x1244 }
"""
DATA_ID = 0x1244

# one node sending two messages of one name, and a third whose id the second database moves
TWINS_DBC = """VERSION ""

BU_: ECU Tester

BO_ 256 Status: 1 ECU
 SG_ A : 0|8@1+ (1,0) [0|255] "" Tester

BO_ 257 Status: 1 ECU
 SG_ B : 0|8@1+ (1,0) [0|255] "" Tester

BO_ {other_id} Other: 1 ECU
 SG_ C : 0|8@1+ (1,0) [0|255] "" Tester

BA_DEF_ BO_ "GenMsgCycleTime" INT 0 65535;
BA_ "GenMsgCycleTime" BO_ 256 20;
BA_ "GenMsgCycleTime" BO_ 257 20;
BA_ "GenMsgCycleTime" BO_ {other_id} 20;
"""

TWINS = """project:
  name: twins
  version: 8
channels:
  - name: T
    type: can
    interface: inproc:PY_TWINS
    databases:
      - twins.dbc
    simulation:
      - name: ECU
"""


def frames(ch, frame_id, within_s=3.0):
    """The frames of `frame_id` on `ch` as they arrive, until within_s has passed."""
    end = time.monotonic() + within_s
    while (left := end - time.monotonic()) > 0:
        f = ch.recv(left * 1000)
        if f is not None and f.id == frame_id:
            yield f


def settles(ch, frame_id, holds, n=5, within_s=3.0):
    """Whether n frames of `frame_id` in a row satisfy `holds` within within_s: frames sent before
    a fault landed are still queued, so the first few may not."""
    run = 0
    for f in frames(ch, frame_id, within_s):
        run = run + 1 if holds(f) else 0
        if run == n:
            return True
    return False


def quiet(ch, frame_id, span_s=0.5, within_s=3.0):
    """Whether `frame_id` is absent from `ch` for span_s at some point within within_s."""
    end = time.monotonic() + within_s
    last = time.monotonic()
    while (now := time.monotonic()) < end:
        if now - last >= span_s:
            return True
        f = ch.recv(min(end - now, 0.05) * 1000)
        if f is not None and f.id == frame_id:
            last = time.monotonic()
    return False


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


class TestOnSimDemo:
    @pytest.fixture
    def net(self, sim_demo):
        yield sim_demo
        sim_demo.clear_faults()

    @pytest.fixture
    def can1(self, net):
        return net.channels.CAN1

    def test_drop_takes_a_message_off_the_bus_and_clearing_brings_it_back(self, net, can1):
        net.fault(can1, "SUT", "Powertrain", FaultKind.DROP)
        assert quiet(can1, POWERTRAIN), "Powertrain still arriving while dropped"
        net.clear_fault("CAN1", "SUT", can1.messages.Powertrain)
        assert next(frames(can1, POWERTRAIN), None) is not None, "Powertrain did not come back"

    def test_a_timed_drop_ends_by_itself(self, net, can1):
        net.fault("CAN1", "SUT", "Heartbeat", "drop", ms=800)
        # a 300 ms silence happens only while the 800 ms drop holds: Heartbeat comes every 100 ms
        assert quiet(can1, HEARTBEAT, span_s=0.3), "Heartbeat still arriving"
        assert next(frames(can1, HEARTBEAT), None) is not None, "Heartbeat did not resume"

    def test_out_of_range_forces_a_signal_past_its_range_until_cleared(self, net, can1):
        brake = can1.messages.BrakeStatus
        pedal = brake.signals.BrakePedal  # 7 bits, declared [0|100]
        outside = lambda f: can1.decode(f)["BrakePedal"] > pedal.maximum  # noqa: E731
        for signal in (pedal, None):  # named, or chosen by the engine: the one that can carry it
            net.fault(can1, "ChassisECU", brake, "out_of_range", signal=signal)
            assert settles(can1, BRAKE_STATUS, outside), f"no BrakePedal past its range (signal={signal})"
            net.clear_fault(can1, "ChassisECU", brake)
            assert settles(can1, BRAKE_STATUS, lambda f: not outside(f)), \
                f"BrakePedal still out of range after the clear (signal={signal})"

    def test_a_fault_that_cannot_take_effect_is_refused_and_says_why(self, net, can1):
        cases = [
            (("CAN1", "SUT", "Powertrain", FaultKind.BAD_CRC), "has no configured checksum"),
            (("CAN1", "SUT", "Heartbeat", "freeze_counter"), "has no E2E counter"),
            (("CAN1", "SUT", "Powertrain", "nonsense"), 'unknown fault kind "nonsense"'),
            (("CAN1", "SUT", "NotAMessage", "drop"), '"SUT" does not send "NotAMessage" on CAN1'),
            (("CAN1", "NoSuchEcu", "Powertrain", "drop"), '"NoSuchEcu" is not simulated on CAN1'),
            (("CAN1", "BodyECU", "BodyStatus", "drop"), '"BodyECU" is not simulated on CAN1'),  # CAN2's
            (("DoIP1", "SUT", "Powertrain", "drop"), "is a DoIP channel"),
            (("CAN1", "SUT", "Powertrain", "out_of_range"), "no signal on \"Powertrain\""),
        ]
        for args, want in cases:
            with pytest.raises(FaultRefused, match=re.escape(want)) as e:
                net.fault(*args)
            assert e.value.code == -1, args
        with pytest.raises(FaultRefused):
            net.fault("CAN1", "SUT", "Powertrain", "out_of_range", signal=can1.messages.Powertrain.signals.EngineSpeed)
        assert issubclass(FaultRefused, blobly.BloblyError)

    def test_arguments_no_fault_can_have_are_python_errors(self, net):
        can2 = net.channels.CAN2
        with pytest.raises(ValueError):
            net.fault("CAN1", "BatteryECU", can2.messages.BatteryStatus, "drop")  # CAN2's message
        for ms in (0, -5):
            with pytest.raises(ValueError):
                net.fault("CAN1", "SUT", "Powertrain", "drop", ms=ms)
        for ms in ("100", float("inf"), True):
            with pytest.raises(TypeError):
                net.fault("CAN1", "SUT", "Powertrain", "drop", ms=ms)
        with pytest.raises(TypeError):
            net.fault("CAN1", None, "Powertrain", "drop")
        with pytest.raises(ValueError):
            net.fault("CAN1", "SUT\0x", "Powertrain", "drop")
        with pytest.raises(KeyError):
            net.fault("NOPE", "SUT", "Powertrain", "drop")


class TestNotStarted:
    def test_a_fault_needs_a_started_project(self):
        net = blobly.Project(SIM_DEMO).load()
        with pytest.raises(blobly.BloblyError) as e:
            net.fault("CAN1", "SUT", "Powertrain", "drop")
        assert not isinstance(e.value, FaultRefused)
        assert e.value.code == -3


def verifies(f):
    return f.data[4] == e2e.p01_crc(f.data, DATA_ID, 4, 5)


@pytest.fixture(scope="class")
def protected(engine, tmp_path_factory):
    """The Profile 1 project started for a class's tests."""
    d = tmp_path_factory.mktemp("e2e")
    write(d / "e2e.dbc", E2E_DBC)
    write(d / "e2e.blobnet", E2E)
    net = blobly.Project(os.fspath(d / "e2e.blobnet")).start()
    yield net
    net.stop()


class TestOnProtectedTraffic:
    """Chassis sends BrakeStatus with AUTOSAR E2E Profile 1: the CRC in byte 4, the counter in
    byte 5's low nibble."""

    @pytest.fixture
    def net(self, protected):
        yield protected
        protected.clear_faults()

    @pytest.fixture
    def ch(self, net):
        return net.channels.E2E

    @staticmethod
    def counters_advance(ch, n=6):
        """Whether n frames in a row each carry the counter after the last's (0..14, wrapping)."""
        last, run = None, 0
        for f in frames(ch, BRAKE_STATUS):
            c = f.data[5] & 0x0F
            run = run + 1 if last is not None and c == (last + 1) % 15 and verifies(f) else 0
            last = c
            if run == n:
                return True
        return False

    def test_the_simulation_stamps_profile_1_as_e2e_computes_it(self, ch):
        assert self.counters_advance(ch)

    def test_bad_crc_breaks_the_crc_until_cleared(self, net, ch):
        net.fault(ch, "Chassis", "BrakeStatus", FaultKind.BAD_CRC)
        inverted = lambda f: f.data[4] == e2e.p01_crc(f.data, DATA_ID, 4, 5) ^ 0xFF  # noqa: E731
        assert settles(ch, BRAKE_STATUS, inverted), "the CRC still verifies under bad_crc"
        net.clear_fault(ch, "Chassis", "BrakeStatus")
        assert self.counters_advance(ch), "the CRC does not verify after the clear"

    def test_freeze_counter_stops_the_counter_until_cleared(self, net, ch):
        net.fault(ch, "Chassis", "BrakeStatus", "freeze_counter")
        seen = []

        def frozen(f):
            seen.append(f.data[5] & 0x0F)
            return verifies(f) and len(seen) > 1 and seen[-1] == seen[-2]
        assert settles(ch, BRAKE_STATUS, frozen), "the counter still advances"
        net.clear_fault(ch, "Chassis", "BrakeStatus")
        assert self.counters_advance(ch), "the counter does not advance after the clear"

    def test_a_timed_fault_on_protected_traffic_ends_by_itself(self, net, ch):
        net.fault(ch, "Chassis", "BrakeStatus", "bad_crc", ms=300)
        assert settles(ch, BRAKE_STATUS, lambda f: not verifies(f), n=3)
        assert self.counters_advance(ch), "the CRC does not verify once the fault ran out"


class TestMessageIdentity:
    """A fault is keyed by the message's name: a Message stands for itself, or is refused."""

    @pytest.fixture
    def twins(self, engine, tmp_path):
        """The project started, and a function that rewrites its database with Other at an id."""
        def write_dbc(other_id):
            write(tmp_path / "twins.dbc", TWINS_DBC.replace("{other_id}", str(other_id)))
        write_dbc(0x102)
        write(tmp_path / "twins.blobnet", TWINS)
        net = blobly.Project(os.fspath(tmp_path / "twins.blobnet")).start()
        yield net, write_dbc
        net.stop()

    def test_a_message_whose_name_is_shared_is_refused_and_the_name_reaches_both(self, twins):
        net, _ = twins
        ch = net.channels.T
        with pytest.raises(ValueError, match="more than one message named Status"):
            net.fault(ch, "ECU", ch.messages[0], "drop")
        net.fault(ch, "ECU", "Status", "drop")
        for frame_id in (0x100, 0x101):
            assert quiet(ch, frame_id), f"0x{frame_id:X} still arriving"

    def test_a_message_its_run_no_longer_has_is_refused(self, twins):
        net, write_dbc = twins
        ch = net.channels.T
        other = ch.messages.Other
        net.stop()
        write_dbc(0x103)  # Other moves: the old object is not this run's
        net.start()
        with pytest.raises(blobly.BloblyError) as e:
            net.fault(ch, "ECU", other, "drop")
        assert e.value.code == -3
        net.fault(ch, "ECU", ch.messages.Other, "drop")
        assert quiet(ch, 0x103), "the current Other still arriving"
