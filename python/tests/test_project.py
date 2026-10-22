"""The package over the real library: projects/sim-demo.blobnet brought up in this process (its
simulated ECUs on inproc buses), its channels, send/recv/health, the event loop against the
simulation, a Python thread attached and let go on itself, and the error paths. Skipped only when
no library is found and BLOBLY_LIB is unset; CI sets it, so a missing build fails there."""
import os
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
# the source tree, unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED)
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import _lib  # noqa: E402


def run_until(net, got, limit_s=5.0):
    """run() in 100 ms slices until got() holds or limit_s has passed: a slow runner waits
    longer, a path that never delivers still fails the assertion after it."""
    deadline = time.monotonic() + limit_s
    while not got() and time.monotonic() < deadline:
        net.run(100)

REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")
DEMO = os.path.join(REPO, "projects", "demo.blobnet")  # its CAN1 is vcan0, sim-demo's inproc:CAN1

# two rows named X on two wires, and a Y on X's first wire to put frames there
DUPLICATES = """project:
  name: duplicates
  version: 8
channels:
  - name: X
    type: can
    interface: inproc:PY_DUP_A
  - name: X
    type: can
    interface: inproc:PY_DUP_B
  - name: Y
    type: can
    interface: inproc:PY_DUP_A
"""


# a database with a multiplexed message, a 29-bit one and two messages of one name
MUX_DBC = """VERSION ""

BU_: A B

BO_ 1024 Muxed: 3 A
 SG_ Mode M : 0|8@1+ (1,0) [0|255] "" B
 SG_ TempA m0 : 8|16@1+ (0.1,0) [0|0] "degC" B
 SG_ PressB m1 : 8|16@1+ (0.5,0) [0|0] "kPa" B

BO_ 2147484160 Wide: 8 A
 SG_ Level : 0|8@1- (1,0) [-128|127] "" B

BO_ 513 Twice: 1 A
 SG_ One : 0|8@1+ (1,0) [0|255] "" B

BO_ 514 Twice: 1 A
 SG_ Two : 0|8@1+ (1,0) [0|255] "" B

BO_ 515 Huge: 1000000000 A

BO_ 2048 PastEleven: 1 A

BO_ 516 Words: 8 A
 SG_ self : 0|8@1+ (1,0) [0|255] "" B
 SG_ Big : 0|64@1+ (1,0) [0|0] "" B

VAL_ 516 Big 9007199254740992 "two to the 53" 9007199254740993 "and one" ;
"""

MUX = """project:
  name: mux
  version: 8
channels:
  - name: M
    type: can
    interface: inproc:PY_MUX
    databases:
      - mux.dbc
"""


def mux_project(d):
    with open(os.path.join(d, "mux.dbc"), "w") as f:
        f.write(MUX_DBC)
    path = os.path.join(d, "mux.blobnet")
    with open(path, "w") as f:
        f.write(MUX)
    return path


def setUpModule():
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or os.environ.get("BLOBLY_TEST_INSTALLED"):
            raise
        raise unittest.SkipTest(str(e))


@unittest.skipUnless(os.environ.get("BLOBLY_TEST_INSTALLED"), "a run of an installed wheel")
class TestInstalledWheel(unittest.TestCase):
    def test_the_installed_package_and_its_own_library_are_what_run(self):
        pkg = os.path.dirname(os.path.abspath(blobly.__file__))
        source = os.path.join(REPO, "python", "blobly")
        self.assertNotEqual(os.path.realpath(pkg), os.path.realpath(source),
                            "the source tree was imported, not the installed wheel")
        self.assertEqual(os.path.dirname(_lib.loaded_path), os.path.join(pkg, "_native"),
                         "the library loaded is not the one the wheel carries")
        self.assertNotIn("+source", blobly.__version__)


class TestChannels(unittest.TestCase):
    def test_the_enabled_rows_are_named_and_complete(self):
        net = blobly.Project(SIM_DEMO).load()
        self.assertEqual(net.channels.keys()[:1], ["CAN1"])
        self.assertIn("CAN2", net.channels.keys())
        self.assertIn("CAN1", dir(net.channels))
        self.assertIs(net.channels.CAN1, net.channels["CAN1"])
        with self.assertRaises(AttributeError) as e:
            net.channels.NOPE
        self.assertIn("CAN1", str(e.exception), "the error names what there is")

    def test_a_channel_needs_a_started_project(self):
        net = blobly.Project(SIM_DEMO).load()
        with self.assertRaises(blobly.BloblyError):
            net.channels.CAN1.recv(0)


class TestLoads(unittest.TestCase):
    def test_a_start_is_its_own_projects_however_the_loads_fell(self):
        a = blobly.Project(SIM_DEMO).load()
        b = blobly.Project(DEMO).load()
        with self.assertRaises(blobly.BloblyError):
            a.channels.CAN1.iface  # the library holds B's load now
        try:
            a.start()
            self.assertEqual(a.channels.CAN1.iface, "inproc:CAN1", "A started B's rows")
            with self.assertRaises(blobly.BloblyError):
                b.channels.CAN1.iface
        finally:
            a.stop()

    def test_a_channel_of_an_earlier_load_refuses(self):
        with blobly.Project(SIM_DEMO) as net:
            old = net.channels.CAN1
        with blobly.Project(SIM_DEMO) as again:
            with self.assertRaises(blobly.BloblyError):
                old.send(0x100, b"")
            again.channels.CAN1.send(0x100, b"")

    def test_two_rows_with_one_name_stay_two_rows(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "duplicates.blobnet")
            with open(path, "w") as f:
                f.write(DUPLICATES)
            with blobly.Project(path) as net:
                with self.assertRaises(blobly.BloblyError):
                    net.channels.X
                first, y = net.channels[0], net.channels.Y
                heard = []
                net.on_message(first, None, heard.append)
                net.on_timer(20, lambda: y.send(0x55, b"\x01"))
                run_until(net, lambda: heard)
                self.assertTrue(heard, "the handler listened to the other row named X")

    def test_a_path_with_a_nul_is_refused(self):
        with self.assertRaises(ValueError):
            blobly.Project(SIM_DEMO + "\0trailing")
        with self.assertRaises(ValueError):
            blobly.Project(os.fsencode(SIM_DEMO) + b"\0trailing")

    def test_a_bytes_path_loads(self):
        net = blobly.Project(os.fsencode(SIM_DEMO)).load()
        self.assertIn("CAN1", net.channels.keys())

    def test_a_timer_closing_over_a_channel_survives_a_reload(self):
        net = blobly.Project(SIM_DEMO)
        with net:
            can1 = net.channels.CAN1
            answers = []
            net.on_message(can1, 0x102, answers.append)
            net.on_timer(30, lambda: can1.send(0x101, b"\x05"))
        blobly.Project(DEMO).load()  # another project's load in between
        try:
            net.start()
            self.assertIs(net.channels.CAN1, can1, "the reload replaced the channel the timer holds")
            run_until(net, lambda: answers)
            self.assertTrue(answers, "no answer to the timer's request after the reload")
        finally:
            net.stop()

    def test_native_state_calls_run_under_the_lock(self):
        lib = _lib.lib()
        real = lib.bb_bus_open
        unlocked = []

        def checked(iface):
            if not _lib.state_lock._is_owned():
                unlocked.append(iface)
            return real(iface)
        lib.bb_bus_open = checked
        try:
            with blobly.Project(SIM_DEMO) as net:
                ts = [threading.Thread(target=lambda c=c: c.recv(0)) for c in (net.channels.CAN1, net.channels.CAN2)]
                for th in ts:
                    th.start()
                for th in ts:
                    th.join()
        finally:
            lib.bb_bus_open = real
        self.assertEqual(unlocked, [], "a bus was opened outside the state lock")

    def test_handlers_follow_a_reload(self):
        net = blobly.Project(SIM_DEMO)
        heard = []
        with net:
            net.on_message("CAN1", None, heard.append)
        blobly.Project(DEMO).load()  # the library holds another load now
        try:
            net.start()  # reloads its own project; the handler must follow
            run_until(net, lambda: heard)
            self.assertTrue(heard, "the handler stayed on the earlier load's channel and heard nothing")
        finally:
            net.stop()

    def test_a_handler_whose_row_went_is_dropped_and_said(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "moving.blobnet")
            with open(path, "w") as f:
                f.write(DUPLICATES.replace("  - name: Y", "  - name: Z"))
            net = blobly.Project(path)
            with net:
                net.on_message(net.channels.Z, None, lambda f: None)
            with open(path, "w") as f:
                f.write(DUPLICATES)  # row 2 is Y now
            with self.assertRaises(blobly.BloblyError) as e:
                net.load()
            self.assertIn("Z", str(e.exception))
            self.assertEqual(net._on_msg, [])

    @unittest.skipIf(sys.platform == "win32", "a non-UTF-8 file name is a POSIX case")
    def test_a_file_name_that_is_not_utf8_loads(self):
        with tempfile.TemporaryDirectory() as d:
            raw = os.path.join(os.fsencode(d), b"project_\xff.blobnet")
            with open(raw, "w") as f:
                f.write(DUPLICATES)
            net = blobly.Project(os.fsdecode(raw)).load()
            self.assertEqual(len(net.channels), 3)


class TestRun(unittest.TestCase):
    def test_frames_health_and_a_send(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            f = can1.recv(1000)
            self.assertIsInstance(f, blobly.Frame)
            self.assertTrue(0 < len(f.data) <= 8)
            self.assertEqual(can1.health(), "", "a software bus has no ladder")
            can1.send(0x7FF, b"\x01\x02")

    def test_the_simulation_answers_through_run(self):
        # sim-demo's SUT answers 0x101 with 0x102, its first byte plus one
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            answers, own = [], []
            net.on_message(can1, 0x102, answers.append)
            net.on_message("CAN1", 0x101, own.append)
            net.on_timer(50, lambda: can1.send(0x101, b"\x05"))
            net.run(400)
            self.assertGreaterEqual(len(answers), 3, answers)
            self.assertEqual(answers[0].data[:1], b"\x06")
            self.assertEqual(own, [], "the script heard its own frames")

    def test_two_channels_are_both_read(self):
        with blobly.Project(SIM_DEMO) as net:
            seen = {"CAN1": 0, "CAN2": 0}

            def count(name):
                return lambda f: seen.__setitem__(name, seen[name] + 1)
            net.on_message("CAN1", None, count("CAN1"))
            net.on_message("CAN2", None, count("CAN2"))
            net.run(300)
            self.assertGreater(seen["CAN1"], 0, seen)
            self.assertGreater(seen["CAN2"], 0, seen)

    def test_stop_then_a_second_run(self):
        with blobly.Project(SIM_DEMO) as net:
            self.assertIsNotNone(net.channels.CAN1.recv(1000))
        with blobly.Project(SIM_DEMO) as net:
            self.assertIsNotNone(net.channels.CAN1.recv(1000))

    def test_one_run_per_process(self):
        with blobly.Project(SIM_DEMO):
            with self.assertRaises(blobly.BloblyError) as e:
                blobly.Project(SIM_DEMO).start()
            self.assertEqual(e.exception.code, _lib.BB_ERR_STATE)


class TestDatabases(unittest.TestCase):
    """CAN1's database in sim-demo is dbc/blobly_net.dbc: Powertrain 0x100, 8 bytes, EngineSpeed
    0|16 at 0.25 rpm, Gear 43|4 with a value table; the SUT answers Request 0x101 with Response
    0x102, ReqCode plus one."""

    def test_the_messages_are_listed_and_complete(self):
        with blobly.Project(SIM_DEMO) as net:
            msgs = net.channels.CAN1.messages
            self.assertIn("Powertrain", dir(msgs))
            pt = msgs.Powertrain
            self.assertIs(pt, msgs["Powertrain"])
            self.assertEqual((pt.id, pt.ext, pt.dlc, pt.j1939), (0x100, False, 8, False))
            self.assertEqual(pt.signals.keys(), ["EngineSpeed", "VehicleSpeed", "CoolantTemp",
                                                 "ThrottlePos", "Gear", "CruiseOn"])
            es = pt.signals.EngineSpeed
            self.assertEqual((es.start_bit, es.length, es.byte_order, es.signed), (0, 16, "little", False))
            self.assertEqual((es.factor, es.offset, es.minimum, es.maximum, es.unit), (0.25, 0, 0, 16383.75, "rpm"))
            self.assertEqual(pt.signals.Gear.labels[3], "Third")
            self.assertEqual(pt.signals.Gear.raw_labels[3], "Third")
            self.assertEqual(len(pt.signals.Gear.labels), 7)
            self.assertEqual(pt.signals.CoolantTemp.offset, -40)
            with self.assertRaises(AttributeError) as e:
                msgs.Nope
            self.assertIn("Powertrain", str(e.exception), "the error names what there is")

    def test_encode_is_send_messages(self):
        with blobly.Project(SIM_DEMO) as net:
            pt = net.channels.CAN1.messages.Powertrain
            f = pt.encode(EngineSpeed=1500, Gear=3, CruiseOn=True)
            # 1500 / 0.25 = 0x1770; Gear 3 << 43; CruiseOn bit 47; the rest raw 0
            self.assertEqual(f, blobly.Frame(0x100, bytes([0x70, 0x17, 0, 0, 0, 0x98, 0, 0])))
            self.assertEqual(pt.encode().data, bytes(8), "every signal unset is raw 0")
            with self.assertRaises(blobly.BloblyError) as e:
                pt.encode(Nope=1)
            self.assertIn('unknown signal "Nope" in Powertrain', str(e.exception))
            with self.assertRaises(TypeError):
                pt.encode(Gear="Third")

    def test_decode_reads_back_what_encode_wrote(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            f = can1.messages.Powertrain.encode(EngineSpeed=1500, CoolantTemp=90, Gear=3)
            self.assertEqual(can1.decode(f), {"EngineSpeed": 1500, "VehicleSpeed": 0, "CoolantTemp": 90,
                                              "ThrottlePos": 0, "Gear": 3, "CruiseOn": 0})
            self.assertIsNone(can1.decode(blobly.Frame(0x7FF, b"\x01")), "a frame of no message")
            self.assertIsNone(can1.decode(blobly.Frame(0x100, ext=True)), "the id of the other kind")
            self.assertIsNone(can1.decode(blobly.Frame(0x100, rtr=True, length=8)), "a remote frame")
            # a short payload carries the signals it holds whole, and no value it lacks the bits for
            self.assertEqual(can1.decode(blobly.Frame(0x100, b"\x70\x17")), {"EngineSpeed": 1500})
            heard = can1.recv(1000)
            self.assertIsNotNone(heard)
            self.assertIsInstance(can1.decode(heard), dict, f"the simulation sent {heard}")

    def test_a_message_sent_is_answered_and_decoded(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            msgs = can1.messages
            answers = []
            net.on_message(can1, msgs.Response, lambda f: answers.append(can1.decode(f)))
            net.on_timer(50, lambda: msgs.Request.send(ReqCode=5))
            net.run(300)
            self.assertTrue(answers)
            self.assertEqual(answers[0], {"RespCode": 6})

    def test_a_message_outlives_a_restart_while_it_is_there(self):
        net = blobly.Project(SIM_DEMO)
        with net:
            pt = net.channels.CAN1.messages.Powertrain
        with self.assertRaises(blobly.BloblyError) as e:
            pt.encode(Gear=1)
        self.assertEqual(e.exception.code, _lib.BB_ERR_STATE, "a stopped run has no databases")
        with self.assertRaises(blobly.BloblyError) as e:
            net.channels.CAN1.messages
        self.assertEqual(e.exception.code, _lib.BB_ERR_STATE, "the stopped run's list was handed out")
        with net:
            self.assertIs(net.channels.CAN1.messages.Powertrain, pt)
            self.assertEqual(pt.encode(Gear=1).data[5], 0x08)

    def test_the_messages_need_a_run(self):
        net = blobly.Project(SIM_DEMO).load()
        with self.assertRaises(blobly.BloblyError) as e:
            net.channels.CAN1.messages
        self.assertEqual(e.exception.code, _lib.BB_ERR_STATE)

    def test_multiplexing_kinds_and_shared_names(self):
        with tempfile.TemporaryDirectory() as d:
            with blobly.Project(mux_project(d)) as net:
                m = net.channels.M
                mux = m.messages.Muxed
                self.assertTrue(mux.signals.Mode.multiplexor)
                self.assertEqual((mux.signals.PressB.multiplexed, mux.signals.PressB.mux_value), (True, 1))
                # only the signals the switch selects
                self.assertEqual(m.decode(mux.encode(Mode=1, PressB=50)), {"Mode": 1, "PressB": 50})
                self.assertEqual(m.decode(mux.encode(Mode=0, TempA=20)), {"Mode": 0, "TempA": 20})
                wide = m.messages.Wide
                self.assertEqual((wide.id, wide.ext, wide.signals.Level.signed), (0x200, True, True))
                self.assertEqual(m.decode(wide.encode(Level=-3)), {"Level": -3})
                with self.assertRaises(blobly.BloblyError):
                    m.messages.Twice  # two messages of one name: by position
                self.assertEqual([x.id for x in m.messages if x.name == "Twice"], [0x201, 0x202])

    def test_awkward_definitions(self):
        with tempfile.TemporaryDirectory() as d:
            with blobly.Project(mux_project(d)) as net:
                m = net.channels.M
                huge = m.messages.Huge  # listed without a payload of its DLC being made
                self.assertEqual(huge.dlc, 1000000000)
                with self.assertRaises(blobly.BloblyError):
                    huge.encode()
                words = m.messages.Words
                self.assertEqual(words.encode(self=5).data[0], 5, "a signal named self")
                big = words.signals.Big
                self.assertEqual(big.raw_labels, {2**53: "two to the 53", 2**53 + 1: "and one"})
                self.assertEqual(len(big.labels), 1, "a double holds one of the two")
                with self.assertRaises(ValueError):
                    words.encode(**{"self\0suffix": 1})
                past = m.messages.PastEleven  # 0x800 with no extended bit: no frame carries it
                self.assertEqual((past.id, past.ext), (0x800, False))
                with self.assertRaises(ValueError) as e:
                    m.expect(past, 0)
                self.assertIn("0x800 is not an 11-bit id (its database's PastEleven)", str(e.exception))


class TestExpect(unittest.TestCase):
    """expect / expect_signal: id AND kind, one deadline for the whole wait, the predicate form,
    and a Timeout that says what came instead."""

    def test_a_frame_is_matched_by_its_id_and_kind(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "duplicates.blobnet")
            with open(path, "w") as f:
                f.write(DUPLICATES)
            with blobly.Project(path) as net:
                x, y = net.channels[0], net.channels.Y  # one wire: X hears what Y sends
                x.recv(0)  # X's handle is open before Y sends
                y.send(0x123, b"\x01", ext=True)
                y.send(0x123, b"\x02")
                self.assertEqual(x.expect(0x123, 1000), blobly.Frame(0x123, b"\x02"),
                                 "the 29-bit 0x123 was taken for the 11-bit one")
                y.send(0x123, b"\x03", ext=True)
                self.assertEqual(x.expect(0x123, 1000, ext=True), blobly.Frame(0x123, b"\x03", ext=True))
                y.send(0x200, b"")
                y.send(0x123, b"\x04", ext=True)
                with self.assertRaises(blobly.Timeout) as e:
                    x.expect(0x123, 100)
                # the expected id's other kind is named first, ahead of the commoner
                self.assertIn("expected a frame 0x123 within 100 ms; 2 other frames came: "
                              "1 of 0x123 (29-bit), 1 of 0x200", str(e.exception))
                self.assertEqual(e.exception.code, _lib.BB_ERR_TIMEOUT)

    def test_the_timeout_is_one_deadline_on_a_busy_bus(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1  # about 90 frames a second, none of them 0x555
            t0 = time.monotonic()
            with self.assertRaises(blobly.Timeout) as e:
                can1.expect(0x555, timeout_ms=300)
            took = (time.monotonic() - t0) * 1000
            # a coarse clock (Windows) may read a little short; a per-frame timeout would never end
            self.assertGreater(took, 250)
            self.assertLess(took, 2000, "the wait ran past its deadline")
            self.assertRegex(str(e.exception), r"\d+ other frames came: \d+ of 0x")
            t0 = time.monotonic()
            with self.assertRaises(blobly.Timeout):
                can1.expect(0x555, timeout_ms=0)  # one look
            self.assertLess((time.monotonic() - t0) * 1000, 500)

    def test_a_signal_by_value_and_by_predicate(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            msgs = can1.messages
            msgs.Request.send(ReqCode=5)
            frame, value = can1.expect_signal("Response", "RespCode", 6, timeout_ms=1000)
            self.assertEqual((frame.id, frame.data[0], value), (0x102, 6, 6.0))
            pt = msgs.Powertrain
            frame, gear = can1.expect_signal(pt, pt.signals.Gear, lambda g: 1 <= g <= 6, timeout_ms=1000)
            self.assertEqual(can1.decode(frame)["Gear"], gear)
            msgs.Request.send(ReqCode=5)
            with self.assertRaises(blobly.Timeout) as e:
                can1.expect_signal("Response", "RespCode", 7, timeout_ms=300)
            self.assertIn("expected Response.RespCode == 7 within 300 ms; 1 Response frame came, "
                          "RespCode was 6.0", str(e.exception))
            with self.assertRaises(blobly.Timeout) as e:
                can1.expect_signal(pt, "EngineSpeed", lambda v: v < 0, timeout_ms=900)
            # a sine at 10 frames a second: more values than are listed one by one
            self.assertRegex(str(e.exception), r"EngineSpeed to satisfy <lambda> within 900 ms; \d+ "
                                               r"Powertrain frames came, EngineSpeed went from [\d.]+ to "
                                               r"[\d.]+, last [\d.]+$")
            with self.assertRaises(blobly.Timeout) as e:
                can1.expect_signal("Response", "RespCode", 6, timeout_ms=100)
            self.assertIn("no Response frame (0x102) came", str(e.exception))

    def test_the_deadline_rule_on_a_synthetic_clock(self):
        clock = [0.0]

        def sleep(ms):
            clock[0] += ms

        ch = blobly.Channel(None, 0, "X", 0)  # its reads are the fakes below; no library behind it
        ch._handle = lambda: 0
        ch._same_run = lambda run: None
        asked = []

        def reads(*looks):
            """_receive answering (frame, spent) after `cost` ms, then nothing after what it asked."""
            looks = list(looks)

            def fake(ms, h=None):
                asked.append(ms)
                frame, spent, cost = looks.pop(0) if looks else (None, False, ms)
                sleep(cost)
                return frame, spent
            return fake
        answer = blobly.Frame(0x102, b"\x06")
        with mock.patch.object(blobly.project, "monotonic_ms", lambda: clock[0]), \
                mock.patch.object(blobly.project, "sleep_ms", sleep):
            # a look that stopped at its bound with records queued is looked again within the deadline
            ch._receive = reads((None, True, 0.2), (answer, False, 0))
            self.assertIs(ch.expect(0x102, 5), answer)
            self.assertEqual(asked, [5, 4])
            # and not past it: a wait of 0 is one look
            asked.clear()
            ch._receive = reads((None, True, 0), (answer, False, 0))
            with self.assertRaises(blobly.Timeout):
                ch.expect(0x102, 0)
            self.assertEqual(asked, [0])
            # whole milliseconds are waited for, never past the deadline, and what is left of it
            # after the last look is slept
            asked.clear()
            clock[0] = 0.0
            ch._receive = reads((None, False, 2), (None, False, 0.3))
            with self.assertRaises(blobly.Timeout):
                ch.expect(0x102, 2.5)
            self.assertEqual(asked, [2, 0])
            self.assertAlmostEqual(clock[0], 2.5, msg="the wait did not end at its deadline")
            # nothing is read once the deadline has passed but the first look
            asked.clear()
            ch._handle = lambda: 0
            ch._receive = reads((blobly.Frame(0x100), False, 2), (answer, False, 0))
            with self.assertRaises(blobly.Timeout):
                ch.expect(0x102, 1)
            self.assertEqual(asked, [1])
            # the channel's first use opens it inside the wait: an open that spent the budget
            # leaves the one look
            asked.clear()
            ch._handle = lambda: sleep(200)
            ch._receive = reads((answer, False, 0))
            self.assertIs(ch.expect(0x102, 100), answer)
            self.assertEqual(asked, [0])

    def test_a_signal_is_its_position_not_its_name(self):
        dbc = ('VERSION ""\n\nBU_: A\n\nBO_ 517 Dups: 2 A\n SG_ Same : 0|8@1+ (1,0) [0|255] "" A\n'
               ' SG_ Same : 8|8@1+ (1,0) [0|255] "" A\n')
        project = ("project:\n  name: dups\n  version: 8\nchannels:\n"
                   "  - name: A\n    type: can\n    interface: inproc:PY_DUPSIG\n    databases:\n      - dups.dbc\n"
                   "  - name: B\n    type: can\n    interface: inproc:PY_DUPSIG\n")
        with tempfile.TemporaryDirectory() as d:
            for name, text in (("dups.dbc", dbc), ("dups.blobnet", project)):
                with open(os.path.join(d, name), "w") as f:
                    f.write(text)
            with blobly.Project(os.path.join(d, "dups.blobnet")) as net:
                a, b = net.channels.A, net.channels.B
                dups = a.messages.Dups
                first, second = dups.signals[0], dups.signals[1]
                a.recv(0)  # A's handle is open before B sends
                b.send(0x205, b"\x01\x02")
                b.send(0x205, b"\x01\x02")
                self.assertEqual(a.expect_signal(dups, second, 2, timeout_ms=500)[1], 2)
                with self.assertRaises(blobly.Timeout) as e:
                    a.expect_signal(dups, first, 2, timeout_ms=100)
                self.assertIn("Same was 1.0", str(e.exception))
                b.send(0x205, b"\x01")  # a short frame: the second Same's bits never came
                with self.assertRaises(blobly.Timeout) as e:
                    a.expect_signal(dups, second, 0, timeout_ms=100)
                self.assertIn("1 Dups frame came, none carrying Same", str(e.exception))
                with self.assertRaises(blobly.BloblyError):
                    a.expect_signal(dups, "Same", 2)  # a name two signals answer to

    def test_a_restart_during_the_wait_is_refused(self):
        with blobly.Project(SIM_DEMO) as net:
            def restart(gear):  # the run another thread could replace while a test waits
                net.stop()
                net.start()
                return False
            for found in (restart, lambda gear: restart(gear) or True):  # a match, too
                with self.assertRaises(blobly.BloblyError) as e:
                    net.channels.CAN1.expect_signal("Powertrain", "Gear", found, timeout_ms=2000)
                self.assertEqual(e.exception.code, _lib.BB_ERR_STATE)
                self.assertIn("restarted during the wait", str(e.exception))
            # a stop while another thread waits closes the handle it reads: the wrong state
            can1, got = net.channels.CAN1, []

            def waiter():
                try:
                    can1.expect(0x555, timeout_ms=3000)
                except blobly.BloblyError as e:
                    got.append(e.code)
            t = threading.Thread(target=waiter)
            t.start()
            time.sleep(0.2)
            net.stop()
            net.start()
            can1.send(0x101, b"\x05")  # an answer the old wait must not take from the new run
            t.join()
            self.assertEqual(got, [_lib.BB_ERR_STATE])
            self.assertEqual(can1.expect(0x102, 1000).data[:1], b"\x06")
            # and found before the next read, whatever that read would have been
            can2 = net.channels.CAN2
            with mock.patch.object(can2, "_receive", wraps=can2._receive) as reads:
                at_restart = []

                def restart_counting(locked):
                    at_restart.append(reads.call_count)
                    return restart(locked)
                with self.assertRaises(blobly.BloblyError) as e:
                    can2.expect_signal("BodyStatus", "Locked", restart_counting, timeout_ms=2000)
                self.assertEqual(e.exception.code, _lib.BB_ERR_STATE)
                self.assertEqual(reads.call_count, at_restart[0], "a frame of the replacement run was read")

    def test_what_no_wait_can_match_is_refused_before_waiting(self):
        with blobly.Project(SIM_DEMO) as net:
            can1, can2 = net.channels.CAN1, net.channels.CAN2
            with self.assertRaises(ValueError) as e:
                can1.expect(0x18DAF110)
            self.assertIn("0x18DAF110 is not an 11-bit id; a 29-bit id is ext=True", str(e.exception))
            for bad in (None, float("nan"), "100"):
                with self.assertRaises(TypeError, msg=repr(bad)):
                    can1.expect(0x102, bad)
            with self.assertRaises(TypeError):
                can1.expect(can1.messages.Response, ext=True)
            with self.assertRaises(ValueError) as e:
                can1.expect_signal(can2.messages.Powertrain, "Gear", 1)
            self.assertIn("Powertrain is a message of CAN2, not of CAN1", str(e.exception))
            with self.assertRaises(KeyError) as e:
                can1.expect_signal("Powertrain", "Gearbox", 1)
            self.assertIn("; there are: EngineSpeed", str(e.exception), "the error names the signals there are")
            with self.assertRaises(KeyError):
                can1.expect_signal("Powertrane", "Gear", 1)
            with self.assertRaises(TypeError):
                can1.expect_signal("Powertrain", "Gear", "Third")
            with self.assertRaises(ValueError) as e:
                can1.expect_signal("Response", can1.messages.Powertrain.signals.Gear, 1)
            self.assertIn("Gear is not a signal of Response", str(e.exception))


class TestRefusals(unittest.TestCase):
    def test_a_frame_that_is_not_one(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            for bad in (123.5, None, "0x100", -1, True, 0x1_0000_0101, 0x2000_0000):
                with self.assertRaises(ValueError, msg=repr(bad)):
                    can1.send(bad, b"")
            with self.assertRaises(ValueError):
                can1.send(0x100, bytes(65))
            for long in (2**31, 2**32):
                with self.assertRaises(ValueError, msg=long):
                    can1.recv(long)
            with self.assertRaises(blobly.BloblyError):
                can1.send(0x800, b"")  # an 11-bit id past its width: the transport refuses it

    def test_an_ethernet_row_is_not_a_bus(self):
        with blobly.Project(SIM_DEMO) as net:
            self.assertEqual(net.channels.DoIP1.kind, "doip")
            self.assertEqual(net.channels.CAN1.kind, "can")
            with self.assertRaises(blobly.BloblyError) as e:
                net.channels.DoIP1.send(0x100, b"")
            self.assertIn("DoIP or SOME/IP", str(e.exception))

    def test_on_health_alone_leaves_a_polled_channel_unread(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1  # inproc: no controller, so nothing for a reader to advance
            waited_on = []
            real = net._wait_frame
            net._wait_frame = lambda chans, ms: (waited_on.append(list(chans)), real(chans, ms))[1]
            net.on_health(can1, lambda s: None)
            net.run(30)
            self.assertTrue(waited_on and all(can1 not in c for c in waited_on))
            net.on_message(can1, None, lambda f: None)
            waited_on.clear()
            net.run(30)
            self.assertTrue(waited_on and all(can1 in c for c in waited_on))

    def test_a_clean_stop_frees_the_process(self):
        net = blobly.Project(SIM_DEMO)
        net.start()
        self.assertTrue(net.stop())
        self.assertTrue(blobly.wait_released(0))
        self.assertTrue(net.stop(), "a second stop asks whether the process is free, and it is")
        with self.assertRaises(ValueError):
            blobly.wait_released(2**31)  # a C int: wider would wrap to forever or to 0


class TestThreads(unittest.TestCase):
    def test_a_python_thread_attaches_and_is_let_go_on_itself(self):
        with blobly.Project(SIM_DEMO) as net:
            failures, ident = [], []

            def work():
                try:
                    ident.append(threading.get_ident())
                    can1 = net.channels.CAN2
                    for _ in range(200):  # unattached, a thread aborts the process by about 10
                        can1.close()
                        can1.recv(0)
                    self.assertIsNotNone(can1.recv(1000))
                except Exception as e:  # any failure on the thread fails the test
                    failures.append(repr(e))
            t = threading.Thread(target=work)
            t.start()
            t.join()
            self.assertEqual(failures, [])
            self.assertIn((ident[0], 0), _lib.detached, "the thread was not detached on itself")


if __name__ == "__main__":
    unittest.main()
