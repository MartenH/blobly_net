"""Fault injection from Python, seen on the bus: projects/sim-demo.blobnet for drop and
out_of_range and for the refusals (it protects nothing, so bad_crc and freeze_counter are refused
there), and a project of one Profile 1 protected message for bad_crc and freeze_counter, checked
with blobly.e2e. Every fault is then cleared and the traffic seen to recover."""
import os
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import FaultKind, FaultRefused, _lib, e2e  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")
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


def setUpModule():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        raise unittest.SkipTest(str(e))


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


class TestOnSimDemo(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.net = blobly.Project(SIM_DEMO).start()
        cls.can1 = cls.net.channels.CAN1

    @classmethod
    def tearDownClass(cls):
        cls.net.stop()

    def tearDown(self):
        self.net.clear_faults()

    def test_drop_takes_a_message_off_the_bus_and_clearing_brings_it_back(self):
        self.net.fault(self.can1, "SUT", "Powertrain", FaultKind.DROP)
        self.assertTrue(quiet(self.can1, POWERTRAIN), "Powertrain still arriving while dropped")
        self.net.clear_fault("CAN1", "SUT", self.can1.messages.Powertrain)
        self.assertIsNotNone(next(frames(self.can1, POWERTRAIN), None), "Powertrain did not come back")

    def test_a_timed_drop_ends_by_itself(self):
        self.net.fault("CAN1", "SUT", "Heartbeat", "drop", ms=800)
        # a 300 ms silence happens only while the 800 ms drop holds: Heartbeat comes every 100 ms
        self.assertTrue(quiet(self.can1, HEARTBEAT, span_s=0.3), "Heartbeat still arriving")
        self.assertIsNotNone(next(frames(self.can1, HEARTBEAT), None), "Heartbeat did not resume")

    def test_out_of_range_forces_a_signal_past_its_range_until_cleared(self):
        brake = self.can1.messages.BrakeStatus
        pedal = brake.signals.BrakePedal  # 7 bits, declared [0|100]
        outside = lambda f: self.can1.decode(f)["BrakePedal"] > pedal.maximum  # noqa: E731
        for signal in (pedal, None):  # named, or chosen by the engine: the one that can carry it
            with self.subTest(signal=signal):
                self.net.fault(self.can1, "ChassisECU", brake, "out_of_range", signal=signal)
                self.assertTrue(settles(self.can1, BRAKE_STATUS, outside), "no BrakePedal past its range")
                self.net.clear_fault(self.can1, "ChassisECU", brake)
                self.assertTrue(settles(self.can1, BRAKE_STATUS, lambda f: not outside(f)),
                                "BrakePedal still out of range after the clear")

    def test_a_fault_that_cannot_take_effect_is_refused_and_says_why(self):
        net = self.net
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
            with self.subTest(args=args):
                with self.assertRaises(FaultRefused) as e:
                    net.fault(*args)
                self.assertIn(want, str(e.exception))
                self.assertEqual(e.exception.code, -1)
        with self.assertRaises(FaultRefused):
            net.fault("CAN1", "SUT", "Powertrain", "out_of_range", signal=self.can1.messages.Powertrain.signals.EngineSpeed)
        self.assertTrue(issubclass(FaultRefused, blobly.BloblyError))

    def test_arguments_no_fault_can_have_are_python_errors(self):
        net, can2 = self.net, self.net.channels.CAN2
        with self.assertRaises(ValueError):
            net.fault("CAN1", "BatteryECU", can2.messages.BatteryStatus, "drop")  # CAN2's message
        for ms in (0, -5):
            with self.assertRaises(ValueError):
                net.fault("CAN1", "SUT", "Powertrain", "drop", ms=ms)
        for ms in ("100", float("inf"), True):
            with self.assertRaises(TypeError):
                net.fault("CAN1", "SUT", "Powertrain", "drop", ms=ms)
        with self.assertRaises(TypeError):
            net.fault("CAN1", None, "Powertrain", "drop")
        with self.assertRaises(ValueError):
            net.fault("CAN1", "SUT\0x", "Powertrain", "drop")
        with self.assertRaises(KeyError):
            net.fault("NOPE", "SUT", "Powertrain", "drop")


class TestNotStarted(unittest.TestCase):
    def test_a_fault_needs_a_started_project(self):
        net = blobly.Project(SIM_DEMO).load()
        with self.assertRaises(blobly.BloblyError) as e:
            net.fault("CAN1", "SUT", "Powertrain", "drop")
        self.assertNotIsInstance(e.exception, FaultRefused)
        self.assertEqual(e.exception.code, -3)


class TestOnProtectedTraffic(unittest.TestCase):
    """Chassis sends BrakeStatus with AUTOSAR E2E Profile 1: the CRC in byte 4, the counter in
    byte 5's low nibble."""

    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory()
        for name, text in (("e2e.dbc", E2E_DBC), ("e2e.blobnet", E2E)):
            with open(os.path.join(cls.dir.name, name), "w") as f:
                f.write(text)
        cls.net = blobly.Project(os.path.join(cls.dir.name, "e2e.blobnet")).start()
        cls.ch = cls.net.channels.E2E

    @classmethod
    def tearDownClass(cls):
        cls.net.stop()
        cls.dir.cleanup()

    def tearDown(self):
        self.net.clear_faults()

    @staticmethod
    def verifies(f):
        return f.data[4] == e2e.p01_crc(f.data, DATA_ID, 4, 5)

    def counters_advance(self, n=6):
        """Whether n frames in a row each carry the counter after the last's (0..14, wrapping)."""
        last, run = None, 0
        for f in frames(self.ch, BRAKE_STATUS):
            c = f.data[5] & 0x0F
            run = run + 1 if last is not None and c == (last + 1) % 15 and self.verifies(f) else 0
            last = c
            if run == n:
                return True
        return False

    def test_the_simulation_stamps_profile_1_as_e2e_computes_it(self):
        self.assertTrue(self.counters_advance())

    def test_bad_crc_breaks_the_crc_until_cleared(self):
        self.net.fault(self.ch, "Chassis", "BrakeStatus", FaultKind.BAD_CRC)
        inverted = lambda f: f.data[4] == e2e.p01_crc(f.data, DATA_ID, 4, 5) ^ 0xFF  # noqa: E731
        self.assertTrue(settles(self.ch, BRAKE_STATUS, inverted), "the CRC still verifies under bad_crc")
        self.net.clear_fault(self.ch, "Chassis", "BrakeStatus")
        self.assertTrue(self.counters_advance(), "the CRC does not verify after the clear")

    def test_freeze_counter_stops_the_counter_until_cleared(self):
        self.net.fault(self.ch, "Chassis", "BrakeStatus", "freeze_counter")
        seen = []

        def frozen(f):
            seen.append(f.data[5] & 0x0F)
            return self.verifies(f) and len(seen) > 1 and seen[-1] == seen[-2]
        self.assertTrue(settles(self.ch, BRAKE_STATUS, frozen), "the counter still advances")
        self.net.clear_fault(self.ch, "Chassis", "BrakeStatus")
        self.assertTrue(self.counters_advance(), "the counter does not advance after the clear")

    def test_a_timed_fault_on_protected_traffic_ends_by_itself(self):
        self.net.fault(self.ch, "Chassis", "BrakeStatus", "bad_crc", ms=300)
        self.assertTrue(settles(self.ch, BRAKE_STATUS, lambda f: not self.verifies(f), n=3))
        self.assertTrue(self.counters_advance(), "the CRC does not verify once the fault ran out")


if __name__ == "__main__":
    unittest.main()
