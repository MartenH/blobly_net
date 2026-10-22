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
            net.on_health(can1, lambda s: None)
            self.assertFalse(any(k is can1 for k in net._listened))
            net.on_message(can1, None, lambda f: None)
            self.assertTrue(any(k is can1 for k in net._listened))

    def test_a_clean_stop_frees_the_process(self):
        net = blobly.Project(SIM_DEMO)
        net.start()
        self.assertTrue(net.stop())
        self.assertTrue(blobly.wait_released(0))
        self.assertTrue(net.stop(), "a second stop asks whether the process is free, and it is")


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
