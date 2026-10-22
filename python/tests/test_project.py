"""The package over the real library: projects/sim-demo.blobnet brought up in this process (its
simulated ECUs on inproc buses), its channels, send/recv/health, the event loop against the
simulation, a Python thread attached and let go on itself, and the error paths. Skipped only when
no library is found and BLOBLY_LIB is unset; CI sets it, so a missing build fails there."""
import os
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import _lib  # noqa: E402

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
        if os.environ.get("BLOBLY_LIB"):
            raise
        raise unittest.SkipTest(str(e))


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
                net.run(200)
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
            net.run(200)
            self.assertTrue(answers)
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
            net.run(200)
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
