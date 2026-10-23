"""The package over the real library: projects/sim-demo.blobnet brought up in this process (its
simulated ECUs on inproc buses), its channels, send/recv/health, the event loop against the
simulation, a Python thread attached and let go on itself, and the error paths. Skipped only when
no library is found and BLOBLY_LIB is unset; CI sets it, so a missing build fails there."""
import copy
import ctypes
import os
import pickle
import re
import socket
import sys
import textwrap
import threading
import time
import warnings
from unittest import mock

import pytest

import blobly
from blobly import _lib
from conftest import DEMO, INSTALLED, REPO, SIM_DEMO, run_python

pytestmark = pytest.mark.usefixtures("engine")


def run_until(net, got, limit_s=5.0):
    """run() in 100 ms slices until got() holds or limit_s has passed: a slow runner waits
    longer, a path that never delivers still fails the assertion after it."""
    deadline = time.monotonic() + limit_s
    while not got() and time.monotonic() < deadline:
        net.run(100)


def write(d, name, text):
    """`text` written to d/name; its path, as a string."""
    path = os.path.join(d, name)
    with open(path, "w") as f:
        f.write(text)
    return path


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


@pytest.fixture
def duplicates(tmp_path):
    """The path of DUPLICATES written to a scratch directory."""
    return write(tmp_path, "duplicates.blobnet", DUPLICATES)


@pytest.fixture
def mux(tmp_path):
    """The path of MUX, with its database beside it."""
    write(tmp_path, "mux.dbc", MUX_DBC)
    return write(tmp_path, "mux.blobnet", MUX)


@pytest.mark.skipif(not INSTALLED, reason="a run of an installed wheel")
class TestInstalledWheel:
    def test_the_installed_package_and_its_own_library_are_what_run(self):
        pkg = os.path.dirname(os.path.abspath(blobly.__file__))
        source = os.path.join(REPO, "python", "blobly")
        assert os.path.realpath(pkg) != os.path.realpath(source), \
            "the source tree was imported, not the installed wheel"
        assert os.path.dirname(_lib.loaded_path) == os.path.join(pkg, "_native"), \
            "the library loaded is not the one the wheel carries"
        assert "+source" not in blobly.__version__


class TestChannels:
    def test_the_enabled_rows_are_named_and_complete(self):
        net = blobly.Project(SIM_DEMO).load()
        assert net.channels.keys()[:1] == ["CAN1"]
        assert "CAN2" in net.channels.keys()
        assert "CAN1" in dir(net.channels)
        assert net.channels.CAN1 is net.channels["CAN1"]
        with pytest.raises(AttributeError) as e:
            net.channels.NOPE
        assert "CAN1" in str(e.value), "the error names what there is"

    def test_a_missing_name_is_an_attribute_error_to_every_asker(self):
        chans = blobly.Project(SIM_DEMO).load().channels
        assert not hasattr(chans, "NOPE")
        assert getattr(chans, "NOPE", None) is None
        twin = copy.copy(chans)  # copy asks the half-built copy for __setstate__
        assert twin.CAN1 is chans.CAN1

    def test_a_channel_needs_a_started_project(self):
        net = blobly.Project(SIM_DEMO).load()
        with pytest.raises(blobly.BloblyError):
            net.channels.CAN1.recv(0)

    def test_a_load_polices_every_handle_on_its_listen_only_wire(self, tmp_path):
        # the native handles, not the package's own: the policy is the loaded project's from the
        # load on, for a handle opened before it, before bb_start and across a stop
        path = write(tmp_path, "silent.blobnet", textwrap.dedent("""\
            project:
              name: silent
              version: 8
            channels:
              - name: S
                type: can
                interface: inproc:PY_OPEN_SILENT
                listen_only: true
            """))
        lib = _lib.lib()

        def open_bus():
            with _lib.state_lock:
                return _lib.check(lib.bb_bus_open(b"inproc:PY_OPEN_SILENT"))

        def close_bus(h):
            with _lib.state_lock:
                lib.bb_bus_close(h)

        def sends(h):
            try:
                _lib.check(lib.bb_bus_send(h, ctypes.byref(_lib.BbFrame(id=0x100, len=1))))
                return True
            except blobly.BloblyError as e:
                assert "listen-only" in str(e)
                return False

        blobly.Project(SIM_DEMO).load()
        early = open_bus()
        try:
            assert sends(early)
            net = blobly.Project(path).load()
            assert not sends(early), "a handle opened before the load"
            before = open_bus()
            try:
                assert not sends(before), "a handle opened before bb_start"
            finally:
                close_bus(before)
            with net:
                assert not sends(early), "during the run"
            assert not sends(early), "after the stop"
            blobly.Project(SIM_DEMO).load()
            assert sends(early), "the next load's policy replaces it"
        finally:
            close_bus(early)
            blobly.Project(SIM_DEMO).load()  # its policy, for the tests after this one


class TestLoads:
    def test_a_start_is_its_own_projects_however_the_loads_fell(self):
        a = blobly.Project(SIM_DEMO).load()
        b = blobly.Project(DEMO).load()
        with pytest.raises(blobly.BloblyError):
            a.channels.CAN1.iface  # the library holds B's load now
        try:
            a.start()
            assert a.channels.CAN1.iface == "inproc:CAN1", "A started B's rows"
            with pytest.raises(blobly.BloblyError):
                b.channels.CAN1.iface
        finally:
            a.stop()

    def test_a_channel_of_an_earlier_load_refuses(self):
        with blobly.Project(SIM_DEMO) as net:
            old = net.channels.CAN1
        with blobly.Project(SIM_DEMO) as again:
            with pytest.raises(blobly.BloblyError):
                old.send(0x100, b"")
            again.channels.CAN1.send(0x100, b"")

    def test_two_rows_with_one_name_stay_two_rows(self, duplicates):
        with blobly.Project(duplicates) as net:
            with pytest.raises(blobly.BloblyError):
                net.channels.X
            first, y = net.channels[0], net.channels.Y
            heard = []
            net.on_message(first, None, heard.append)
            net.on_timer(20, lambda: y.send(0x55, b"\x01"))
            run_until(net, lambda: heard)
            assert heard, "the handler listened to the other row named X"

    def test_a_path_with_a_nul_is_refused(self):
        with pytest.raises(ValueError):
            blobly.Project(SIM_DEMO + "\0trailing")
        with pytest.raises(ValueError):
            blobly.Project(os.fsencode(SIM_DEMO) + b"\0trailing")

    def test_a_bytes_path_loads(self):
        net = blobly.Project(os.fsencode(SIM_DEMO)).load()
        assert "CAN1" in net.channels.keys()

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
            assert net.channels.CAN1 is can1, "the reload replaced the channel the timer holds"
            run_until(net, lambda: answers)
            assert answers, "no answer to the timer's request after the reload"
        finally:
            net.stop()

    def test_native_state_calls_run_under_the_lock(self):
        lib = _lib.lib()
        real = lib.bb_bus_open
        unlocked, opened, failed = [], [], []

        def checked(iface):
            opened.append(iface)
            if not _lib.state_lock._is_owned():
                unlocked.append(iface)
            return real(iface)

        def recv(c):
            try:
                c.recv(0)
            except BaseException as e:  # the check is only as good as the threads that ran it
                failed.append(e)
        lib.bb_bus_open = checked
        try:
            with blobly.Project(SIM_DEMO) as net:
                ts = [threading.Thread(target=recv, args=(c,)) for c in (net.channels.CAN1, net.channels.CAN2)]
                for th in ts:
                    th.start()
                for th in ts:
                    th.join()
        finally:
            lib.bb_bus_open = real
        assert failed == []
        assert len(opened) == 2, opened
        assert unlocked == [], "a bus was opened outside the state lock"

    def test_handlers_follow_a_reload(self):
        net = blobly.Project(SIM_DEMO)
        heard = []
        with net:
            net.on_message("CAN1", None, heard.append)
        blobly.Project(DEMO).load()  # the library holds another load now
        try:
            net.start()  # reloads its own project; the handler must follow
            run_until(net, lambda: heard)
            assert heard, "the handler stayed on the earlier load's channel and heard nothing"
        finally:
            net.stop()

    def test_a_handler_whose_row_went_is_dropped_and_said(self, tmp_path):
        path = write(tmp_path, "moving.blobnet", DUPLICATES.replace("  - name: Y", "  - name: Z"))
        net = blobly.Project(path)
        with net:
            net.on_message(net.channels.Z, None, lambda f: None)
        write(tmp_path, "moving.blobnet", DUPLICATES)  # row 2 is Y now
        with pytest.warns(RuntimeWarning) as w:
            net.load()
        assert "Z (row 2)" in str(w[0].message)
        assert w[0].filename == __file__, "said from the line that loaded"
        assert net._on_msg == []
        with net:
            net.on_message(net.channels.Y, None, lambda f: None)
        write(tmp_path, "moving.blobnet", DUPLICATES.replace("  - name: Y", "  - name: Z"))
        blobly.Project(SIM_DEMO).load()  # so the with block's start reloads, and drops Y's handler
        with pytest.warns(RuntimeWarning) as w:
            net.__enter__()
        try:
            assert "Y (row 2)" in str(w[0].message)
            assert w[0].filename == __file__
            assert net.started, "start() said the dropped handlers and did not start"
            net.channels.Z.recv(0)
            net.on_message(net.channels.Z, None, lambda f: None)
        finally:
            net.stop()
        write(tmp_path, "moving.blobnet", DUPLICATES)
        blobly.Project(SIM_DEMO).load()
        with warnings.catch_warnings():
            warnings.simplefilter("error")
            with pytest.raises(RuntimeWarning):
                net.start()
        assert not net.started, "a warning made an error left a run behind it"
        assert blobly.wait_released(0)

    @pytest.mark.skipif(sys.platform == "win32", reason="a non-UTF-8 file name is a POSIX case")
    def test_a_file_name_that_is_not_utf8_loads(self, tmp_path):
        raw = os.path.join(os.fsencode(tmp_path), b"project_\xff.blobnet")
        with open(raw, "w") as f:
            f.write(DUPLICATES)
        net = blobly.Project(os.fsdecode(raw)).load()
        assert len(net.channels) == 3


class TestFrame:
    def test_a_frame_is_a_value(self):
        a, b = blobly.Frame(0x100, b"\x01"), blobly.Frame(0x100, bytearray(b"\x01"))
        assert len({a, b, blobly.Frame(0x100, b"\x01", ext=True)}) == 2
        assert {a: 1}[b] == 1
        with pytest.raises(AttributeError):
            a.data = b"\x02"
        for twin in (copy.copy(a), copy.deepcopy(a), pickle.loads(pickle.dumps(a))):
            assert twin == a
        remote = blobly.Frame(0x100, rtr=True, length=4)
        assert copy.copy(remote).length == 4
        with pytest.raises(AttributeError):
            del a.data

        class Tagged(blobly.Frame):
            __slots__ = ()
        t = Tagged(0x7, b"\x09")
        assert (t.id, t.data) == (0x7, b"\x09")
        assert type(copy.copy(t)) is Tagged

        class Stamped(blobly.Frame):
            __slots__ = ("t",)
        s = Stamped(0x8)
        object.__setattr__(s, "t", 1.5)
        for twin in (copy.copy(s), copy.deepcopy(s)):  # deepcopy goes the way pickle does
            assert (type(twin), twin.t, twin.id) == (Stamped, 1.5, 0x8)
        # Frame(0x7, b"\x09") as the package pickled it before a frame refused assignment
        old = b"\x80\x04\x95f\x00\x00\x00\x00\x00\x00\x00\x8c\x0eblobly.project\x94\x8c\x05Frame\x94\x93\x94)\x81\x94N}\x94(\x8c\x02id\x94K\x07\x8c\x04data\x94C\x01\t\x94\x8c\x06length\x94K\x01\x8c\x03ext\x94\x89\x8c\x02fd\x94\x89\x8c\x03brs\x94\x89\x8c\x03rtr\x94\x89\x8c\x03esi\x94\x89u\x86\x94b."
        assert pickle.loads(old) == blobly.Frame(0x7, b"\x09")
        assert pickle.loads(old).t_ms is None

    def test_the_receive_time_is_not_part_of_the_value(self):
        received = blobly.Frame(0x100, b"\x01", t_ms=12.5)
        assert received == blobly.Frame(0x100, b"\x01")
        assert hash(received) == hash(blobly.Frame(0x100, b"\x01", t_ms=99.0))
        assert pickle.loads(pickle.dumps(received)).t_ms == 12.5
        assert blobly.Frame(0x100).t_ms is None

    def test_the_receive_time_in_ms_is_the_ns_divided_once(self):
        # the Lua binding's clock_ms makes the same division (events_test.v pins the same value)
        assert _lib.ms_of(1_234_567_890_123_456) == 1234567890.123456


# two wires of SocketCAN, each with a row to listen on and one to send from
VCANS = """project:
  name: vcans
  version: 8
channels:
  - name: A
    type: can
    interface: vcan0
  - name: TA
    type: can
    interface: vcan0
  - name: B
    type: can
    interface: vcan1
  - name: TB
    type: can
    interface: vcan1
"""


class TestReceiveTime:
    def test_a_received_frame_carries_its_receipt(self, duplicates):
        with blobly.Project(duplicates) as net:
            x, y = net.channels[0], net.channels.Y
            x.recv(0)
            y.send(0x123, b"\x01")
            y.send(0x124, b"\x02")
            before = blobly.now_ms()
            first = x.recv(1000)
            second = x.recv(1000)
            assert before <= first.t_ms < second.t_ms <= blobly.now_ms(), (before, first.t_ms, second.t_ms)
            assert isinstance(first.t_ms, float)

    @pytest.mark.skipif(not (sys.platform.startswith("linux") and os.path.exists("/sys/class/net/vcan1")),
                        reason="needs vcan0 and vcan1 (scripts/setup_vcan.sh)")
    def test_frames_on_two_wires_are_placed_by_their_kernel_stamps(self, tmp_path):
        with blobly.Project(write(tmp_path, "vcans.blobnet", VCANS)) as net:
            a, b = net.channels.A, net.channels.B
            a.recv(0)
            b.recv(0)
            before = blobly.now_ms()
            net.channels.TA.send(0x151, b"\x5e\x07\x11\xa1")
            net.channels.TB.send(0x151, b"\x5e\x07\x11\xa2")
            later = b.expect(0x151, 1000)  # the later wire is read first
            time.sleep(0.002)
            earlier = a.expect(0x151, 1000)
            assert (earlier.data[-1], later.data[-1]) == (0xa1, 0xa2)
            assert before <= earlier.t_ms < later.t_ms, (before, earlier.t_ms, later.t_ms)


# a row nothing sends on (or answers a flash on), and a script that waits on it — or on a SOME/IP
# port — until a SIGINT, which a timer thread raises as Ctrl-C does: from outside the main thread,
# while the main thread is in the library
QUIET = """project:
  name: quiet
  version: 8
channels:
  - name: Q
    type: can
    interface: inproc:PY_QUIET
"""
INTERRUPTED = textwrap.dedent("""
    import os, signal, sys, threading, time
    sys.path.insert(0, sys.argv[1])
    import blobly
    sent = []

    def ctrl_c():
        sent.append(time.monotonic())
        if sys.platform == "win32":
            signal.raise_signal(signal.SIGINT)  # the console's Ctrl-C handler runs on a thread too
        else:
            os.kill(os.getpid(), signal.SIGINT)
    with blobly.Project(sys.argv[2]) as net:
        q = net.channels.Q
        net.on_message(q, None, print)
        threading.Timer(0.3, ctrl_c).start()
        try:
            {"recv": lambda: q.recv(None), "expect": lambda: q.expect(1, 3_600_000),
             "run": lambda: net.run(3_600_000), "someip": lambda: blobly.someip.listen(3_600_000, port=int(sys.argv[4])),
             "flash": lambda: blobly.flash.program(q, bytes(64), quiet=True)}[sys.argv[3]]()
        except KeyboardInterrupt:
            print(f"interrupted {time.monotonic() - sent[0]:.3f} s after Ctrl-C")
""")


class TestInterrupt:
    @pytest.mark.parametrize("wait", ["recv", "expect", "run", "someip", "flash"])
    def test_ctrl_c_ends_a_long_wait(self, tmp_path, wait):
        pkg = os.path.dirname(os.path.dirname(os.path.abspath(blobly.__file__)))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.bind(("127.0.0.1", 0))  # a port for the SOME/IP listen, free now
            port = str(s.getsockname()[1])
        out = run_python("-c", INTERRUPTED, pkg, write(tmp_path, "quiet.blobnet", QUIET), wait, port, timeout=60)
        late = [float(line.split()[1]) for line in out.stdout.splitlines() if line.startswith("interrupted")]
        assert late, out.stdout + out.stderr
        assert late[0] < 0.5, "Ctrl-C waited for the wait, or a second of run(), to end"


class TestRun:
    def test_frames_health_and_a_send(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            f = can1.recv(1000)
            assert isinstance(f, blobly.Frame)
            assert 0 < len(f.data) <= 8
            assert can1.health() == "", "a software bus has no ladder"
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
            assert len(answers) >= 3, answers
            assert answers[0].data[:1] == b"\x06"
            assert own == [], "the script heard its own frames"

    def test_two_channels_are_both_read(self):
        with blobly.Project(SIM_DEMO) as net:
            seen = {"CAN1": 0, "CAN2": 0}

            def count(name):
                return lambda f: seen.__setitem__(name, seen[name] + 1)
            net.on_message("CAN1", None, count("CAN1"))
            net.on_message("CAN2", None, count("CAN2"))
            net.run(300)
            assert seen["CAN1"] > 0, seen
            assert seen["CAN2"] > 0, seen

    def test_stop_then_a_second_run(self):
        with blobly.Project(SIM_DEMO) as net:
            assert net.channels.CAN1.recv(1000) is not None
        with blobly.Project(SIM_DEMO) as net:
            assert net.channels.CAN1.recv(1000) is not None

    def test_one_run_per_process(self):
        with blobly.Project(SIM_DEMO):
            with pytest.raises(blobly.BloblyError) as e:
                blobly.Project(SIM_DEMO).start()
            assert e.value.code == _lib.BB_ERR_STATE


class TestDatabases:
    """CAN1's database in sim-demo is dbc/blobly_net.dbc: Powertrain 0x100, 8 bytes, EngineSpeed
    0|16 at 0.25 rpm, Gear 43|4 with a value table; the SUT answers Request 0x101 with Response
    0x102, ReqCode plus one."""

    def test_the_messages_are_listed_and_complete(self):
        with blobly.Project(SIM_DEMO) as net:
            msgs = net.channels.CAN1.messages
            assert "Powertrain" in dir(msgs)
            pt = msgs.Powertrain
            assert pt is msgs["Powertrain"]
            assert (pt.id, pt.ext, pt.dlc, pt.j1939) == (0x100, False, 8, False)
            assert pt.signals.keys() == ["EngineSpeed", "VehicleSpeed", "CoolantTemp", "ThrottlePos", "Gear",
                                         "CruiseOn"]
            es = pt.signals.EngineSpeed
            assert (es.start_bit, es.length, es.byte_order, es.signed) == (0, 16, "little", False)
            assert (es.factor, es.offset, es.minimum, es.maximum, es.unit) == (0.25, 0, 0, 16383.75, "rpm")
            assert pt.signals.Gear.labels[3] == "Third"
            assert pt.signals.Gear.raw_labels[3] == "Third"
            assert len(pt.signals.Gear.labels) == 7
            assert pt.signals.CoolantTemp.offset == -40
            with pytest.raises(AttributeError) as e:
                msgs.Nope
            assert "Powertrain" in str(e.value), "the error names what there is"

    def test_encode_is_send_messages(self):
        with blobly.Project(SIM_DEMO) as net:
            pt = net.channels.CAN1.messages.Powertrain
            f = pt.encode(EngineSpeed=1500, Gear=3, CruiseOn=True)
            # 1500 / 0.25 = 0x1770; Gear 3 << 43; CruiseOn bit 47; the rest raw 0
            assert f == blobly.Frame(0x100, bytes([0x70, 0x17, 0, 0, 0, 0x98, 0, 0]))
            assert pt.encode().data == bytes(8), "every signal unset is raw 0"
            with pytest.raises(blobly.BloblyError, match=re.escape('unknown signal "Nope" in Powertrain')):
                pt.encode(Nope=1)
            with pytest.raises(TypeError):
                pt.encode(Gear="Third")

    def test_decode_reads_back_what_encode_wrote(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            f = can1.messages.Powertrain.encode(EngineSpeed=1500, CoolantTemp=90, Gear=3)
            assert can1.decode(f) == {"EngineSpeed": 1500, "VehicleSpeed": 0, "CoolantTemp": 90, "ThrottlePos": 0,
                                      "Gear": 3, "CruiseOn": 0}
            assert can1.decode(blobly.Frame(0x7FF, b"\x01")) is None, "a frame of no message"
            assert can1.decode(blobly.Frame(0x100, ext=True)) is None, "the id of the other kind"
            assert can1.decode(blobly.Frame(0x100, rtr=True, length=8)) is None, "a remote frame"
            # a short payload carries the signals it holds whole, and no value it lacks the bits for
            assert can1.decode(blobly.Frame(0x100, b"\x70\x17")) == {"EngineSpeed": 1500}
            heard = can1.recv(1000)
            assert heard is not None
            assert isinstance(can1.decode(heard), dict), f"the simulation sent {heard}"

    def test_a_message_sent_is_answered_and_decoded(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            msgs = can1.messages
            answers = []
            net.on_message(can1, msgs.Response, lambda f: answers.append(can1.decode(f)))
            net.on_timer(50, lambda: msgs.Request.send(ReqCode=5))
            net.run(300)
            assert answers
            assert answers[0] == {"RespCode": 6}

    def test_a_message_outlives_a_restart_while_it_is_there(self):
        net = blobly.Project(SIM_DEMO)
        with net:
            pt = net.channels.CAN1.messages.Powertrain
        with pytest.raises(blobly.BloblyError) as e:
            pt.encode(Gear=1)
        assert e.value.code == _lib.BB_ERR_STATE, "a stopped run has no databases"
        with pytest.raises(blobly.BloblyError) as e:
            net.channels.CAN1.messages
        assert e.value.code == _lib.BB_ERR_STATE, "the stopped run's list was handed out"
        with net:
            assert net.channels.CAN1.messages.Powertrain is pt
            assert pt.encode(Gear=1).data[5] == 0x08

    def test_the_messages_need_a_run(self):
        net = blobly.Project(SIM_DEMO).load()
        with pytest.raises(blobly.BloblyError) as e:
            net.channels.CAN1.messages
        assert e.value.code == _lib.BB_ERR_STATE

    def test_multiplexing_kinds_and_shared_names(self, mux):
        with blobly.Project(mux) as net:
            m = net.channels.M
            muxed = m.messages.Muxed
            assert muxed.signals.Mode.multiplexor
            assert (muxed.signals.PressB.multiplexed, muxed.signals.PressB.mux_value) == (True, 1)
            # only the signals the switch selects
            assert m.decode(muxed.encode(Mode=1, PressB=50)) == {"Mode": 1, "PressB": 50}
            assert m.decode(muxed.encode(Mode=0, TempA=20)) == {"Mode": 0, "TempA": 20}
            wide = m.messages.Wide
            assert (wide.id, wide.ext, wide.signals.Level.signed) == (0x200, True, True)
            assert m.decode(wide.encode(Level=-3)) == {"Level": -3}
            with pytest.raises(blobly.BloblyError):
                m.messages.Twice  # two messages of one name: by position
            assert [x.id for x in m.messages if x.name == "Twice"] == [0x201, 0x202]

    def test_awkward_definitions(self, mux):
        with blobly.Project(mux) as net:
            m = net.channels.M
            huge = m.messages.Huge  # listed without a payload of its DLC being made
            assert huge.dlc == 1000000000
            with pytest.raises(blobly.BloblyError):
                huge.encode()
            words = m.messages.Words
            assert words.encode(self=5).data[0] == 5, "a signal named self"
            big = words.signals.Big
            assert big.raw_labels == {2**53: "two to the 53", 2**53 + 1: "and one"}
            assert len(big.labels) == 1, "a double holds one of the two"
            with pytest.raises(ValueError):
                words.encode(**{"self\0suffix": 1})
            past = m.messages.PastEleven  # 0x800 with no extended bit: no frame carries it
            assert (past.id, past.ext) == (0x800, False)
            with pytest.raises(ValueError, match=re.escape("0x800 is not an 11-bit id (its database's PastEleven)")):
                m.expect(past, 0)


class TestExpect:
    """expect / expect_signal: id AND kind, one deadline for the whole wait, the predicate form,
    and a Timeout that says what came instead."""

    def test_a_frame_is_matched_by_its_id_and_kind(self, duplicates):
        with blobly.Project(duplicates) as net:
            x, y = net.channels[0], net.channels.Y  # one wire: X hears what Y sends
            x.recv(0)  # X's handle is open before Y sends
            y.send(0x123, b"\x01", ext=True)
            y.send(0x123, b"\x02")
            assert x.expect(0x123, 1000) == blobly.Frame(0x123, b"\x02"), \
                "the 29-bit 0x123 was taken for the 11-bit one"
            y.send(0x123, b"\x03", ext=True)
            assert x.expect(0x123, 1000, ext=True) == blobly.Frame(0x123, b"\x03", ext=True)
            y.send(0x200, b"")
            y.send(0x123, b"\x04", ext=True)
            with pytest.raises(blobly.Timeout) as e:
                x.expect(0x123, 100)
            # the expected id's other kind is named first, ahead of the commoner
            assert ("expected a frame 0x123 within 100 ms; 2 other frames came: "
                    "1 of 0x123 (29-bit), 1 of 0x200") in str(e.value)
            assert e.value.code == _lib.BB_ERR_TIMEOUT

    def test_the_timeout_is_one_deadline_on_a_busy_bus(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1  # about 90 frames a second, none of them 0x555
            t0 = time.monotonic()
            with pytest.raises(blobly.Timeout, match=r"\d+ other frames came: \d+ of 0x"):
                can1.expect(0x555, timeout_ms=300)
            took = (time.monotonic() - t0) * 1000
            # a coarse clock (Windows) may read a little short; a per-frame timeout would never end
            assert took > 250
            assert took < 2000, "the wait ran past its deadline"
            t0 = time.monotonic()
            with pytest.raises(blobly.Timeout):
                can1.expect(0x555, timeout_ms=0)  # one look
            assert (time.monotonic() - t0) * 1000 < 500

    def test_a_signal_by_value_and_by_predicate(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            msgs = can1.messages
            msgs.Request.send(ReqCode=5)
            frame, value = can1.expect_signal("Response", "RespCode", 6, timeout_ms=1000)
            assert (frame.id, frame.data[0], value) == (0x102, 6, 6.0)
            pt = msgs.Powertrain
            frame, gear = can1.expect_signal(pt, pt.signals.Gear, lambda g: 1 <= g <= 6, timeout_ms=1000)
            assert can1.decode(frame)["Gear"] == gear
            msgs.Request.send(ReqCode=5)
            with pytest.raises(blobly.Timeout, match=re.escape(
                    "expected Response.RespCode == 7 within 300 ms; 1 Response frame came, RespCode was 6.0")):
                can1.expect_signal("Response", "RespCode", 7, timeout_ms=300)
            # a sine at 10 frames a second: more values than are listed one by one
            with pytest.raises(blobly.Timeout, match=r"EngineSpeed to satisfy <lambda> within 900 ms; \d+ "
                                                     r"Powertrain frames came, EngineSpeed went from [\d.]+ to "
                                                     r"[\d.]+, last [\d.]+$"):
                can1.expect_signal(pt, "EngineSpeed", lambda v: v < 0, timeout_ms=900)
            with pytest.raises(blobly.Timeout, match=re.escape("no Response frame (0x102) came")):
                can1.expect_signal("Response", "RespCode", 6, timeout_ms=100)

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
            assert ch.expect(0x102, 5) is answer
            assert asked == [5, 4]
            # and not past it: a wait of 0 is one look
            asked.clear()
            ch._receive = reads((None, True, 0), (answer, False, 0))
            with pytest.raises(blobly.Timeout):
                ch.expect(0x102, 0)
            assert asked == [0]
            # whole milliseconds are waited for, never past the deadline, and what is left of it
            # after the last look is slept
            asked.clear()
            clock[0] = 0.0
            ch._receive = reads((None, False, 2), (None, False, 0.3))
            with pytest.raises(blobly.Timeout):
                ch.expect(0x102, 2.5)
            assert asked == [2, 0]
            assert clock[0] == pytest.approx(2.5), "the wait did not end at its deadline"
            # nothing is read once the deadline has passed but the first look
            asked.clear()
            ch._handle = lambda: 0
            ch._receive = reads((blobly.Frame(0x100), False, 2), (answer, False, 0))
            with pytest.raises(blobly.Timeout):
                ch.expect(0x102, 1)
            assert asked == [1]
            # the channel's first use opens it inside the wait: an open that spent the budget
            # leaves the one look
            asked.clear()
            ch._handle = lambda: sleep(200)
            ch._receive = reads((answer, False, 0))
            assert ch.expect(0x102, 100) is answer
            assert asked == [0]

    def test_a_signal_is_its_position_not_its_name(self, tmp_path):
        write(tmp_path, "dups.dbc", 'VERSION ""\n\nBU_: A\n\nBO_ 517 Dups: 2 A\n SG_ Same : 0|8@1+ (1,0) [0|255] "" A\n'
                                    ' SG_ Same : 8|8@1+ (1,0) [0|255] "" A\n')
        path = write(tmp_path, "dups.blobnet", "project:\n  name: dups\n  version: 8\nchannels:\n"
                     "  - name: A\n    type: can\n    interface: inproc:PY_DUPSIG\n    databases:\n      - dups.dbc\n"
                     "  - name: B\n    type: can\n    interface: inproc:PY_DUPSIG\n")
        with blobly.Project(path) as net:
            a, b = net.channels.A, net.channels.B
            dups = a.messages.Dups
            first, second = dups.signals[0], dups.signals[1]
            a.recv(0)  # A's handle is open before B sends
            b.send(0x205, b"\x01\x02")
            b.send(0x205, b"\x01\x02")
            assert a.expect_signal(dups, second, 2, timeout_ms=500)[1] == 2
            with pytest.raises(blobly.Timeout, match=re.escape("Same was 1.0")):
                a.expect_signal(dups, first, 2, timeout_ms=100)
            b.send(0x205, b"\x01")  # a short frame: the second Same's bits never came
            with pytest.raises(blobly.Timeout, match=re.escape("1 Dups frame came, none carrying Same")):
                a.expect_signal(dups, second, 0, timeout_ms=100)
            with pytest.raises(blobly.BloblyError):
                a.expect_signal(dups, "Same", 2)  # a name two signals answer to

    def test_a_restart_during_the_wait_is_refused(self):
        with blobly.Project(SIM_DEMO) as net:
            def restart(gear):  # the run another thread could replace while a test waits
                net.stop()
                net.start()
                return False
            for found in (restart, lambda gear: restart(gear) or True):  # a match, too
                with pytest.raises(blobly.BloblyError, match="restarted during the wait") as e:
                    net.channels.CAN1.expect_signal("Powertrain", "Gear", found, timeout_ms=2000)
                assert e.value.code == _lib.BB_ERR_STATE
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
            assert got == [_lib.BB_ERR_STATE]
            assert can1.expect(0x102, 1000).data[:1] == b"\x06"
            # and found before the next read, whatever that read would have been
            can2 = net.channels.CAN2
            with mock.patch.object(can2, "_receive", wraps=can2._receive) as reads:
                at_restart = []

                def restart_counting(locked):
                    at_restart.append(reads.call_count)
                    return restart(locked)
                with pytest.raises(blobly.BloblyError) as e:
                    can2.expect_signal("BodyStatus", "Locked", restart_counting, timeout_ms=2000)
                assert e.value.code == _lib.BB_ERR_STATE
                assert reads.call_count == at_restart[0], "a frame of the replacement run was read"

    def test_what_no_wait_can_match_is_refused_before_waiting(self):
        with blobly.Project(SIM_DEMO) as net:
            can1, can2 = net.channels.CAN1, net.channels.CAN2
            with pytest.raises(ValueError, match=re.escape("0x18DAF110 is not an 11-bit id; a 29-bit id is ext=True")):
                can1.expect(0x18DAF110)
            for bad in (None, float("nan"), "100"):
                with pytest.raises(TypeError):
                    can1.expect(0x102, bad)
            with pytest.raises(TypeError):
                can1.expect(can1.messages.Response, ext=True)
            with pytest.raises(ValueError, match="Powertrain is a message of CAN2, not of CAN1"):
                can1.expect_signal(can2.messages.Powertrain, "Gear", 1)
            with pytest.raises(KeyError) as e:
                can1.expect_signal("Powertrain", "Gearbox", 1)
            assert "; there are: EngineSpeed" in str(e.value), "the error names the signals there are"
            with pytest.raises(KeyError):
                can1.expect_signal("Powertrane", "Gear", 1)
            with pytest.raises(TypeError):
                can1.expect_signal("Powertrain", "Gear", "Third")
            with pytest.raises(ValueError, match="Gear is not a signal of Response"):
                can1.expect_signal("Response", can1.messages.Powertrain.signals.Gear, 1)


class TestRefusals:
    def test_a_frame_that_is_not_one(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1
            for bad in (123.5, None, "0x100", -1, True, 0x1_0000_0101, 0x2000_0000):
                with pytest.raises(ValueError):
                    can1.send(bad, b"")
            with pytest.raises(ValueError):
                can1.send(0x100, bytes(65))
            for long in (2**31, 2**32):
                with pytest.raises(ValueError):
                    can1.recv(long)
            with pytest.raises(blobly.BloblyError):
                can1.send(0x800, b"")  # an 11-bit id past its width: the transport refuses it

    def test_an_ethernet_row_is_not_a_bus(self):
        with blobly.Project(SIM_DEMO) as net:
            assert net.channels.DoIP1.kind == "doip"
            assert net.channels.CAN1.kind == "can"
            with pytest.raises(blobly.BloblyError, match="DoIP or SOME/IP"):
                net.channels.DoIP1.send(0x100, b"")

    def test_on_health_alone_leaves_a_polled_channel_unread(self):
        with blobly.Project(SIM_DEMO) as net:
            can1 = net.channels.CAN1  # inproc: no controller, so nothing for a reader to advance
            waited_on = []
            real = net._wait_frame
            net._wait_frame = lambda chans, ms: (waited_on.append(list(chans)), real(chans, ms))[1]
            net.on_health(can1, lambda s: None)
            net.run(30)
            assert waited_on and all(can1 not in c for c in waited_on)
            net.on_message(can1, None, lambda f: None)
            waited_on.clear()
            net.run(30)
            assert waited_on and all(can1 in c for c in waited_on)

    def test_a_clean_stop_frees_the_process(self):
        net = blobly.Project(SIM_DEMO)
        net.start()
        assert net.stop()
        assert blobly.wait_released(0)
        assert net.stop(), "a second stop asks whether the process is free, and it is"
        with pytest.raises(ValueError):
            blobly.wait_released(2**31)  # a C int: wider would wrap to forever or to 0

    def test_wait_released_is_asked_in_slices(self):
        from blobly import events
        lib = _lib.lib()
        real, asked = lib.bb_wait_released, []
        t = {"now": 0.0, "tick": 0.0, "late": 0.0}

        def read():  # the clock as a host reads it: in ticks (Windows: about 15.6 ms)
            return t["now"] // t["tick"] * t["tick"] if t["tick"] else t["now"]

        def releasing(ms, free_at=None):  # a driver that wakes `late` ms after what it was asked
            asked.append((read(), ms))
            t["now"] += ms + t["late"] if ms else 0  # a look waits for nothing
            return 0 if free_at and len(asked) >= free_at else _lib.BB_RELEASING
        try:
            with mock.patch.object(events, "monotonic_ms", read), \
                    mock.patch.object(events, "sleep_ms", lambda ms: t.__setitem__("now", t["now"] + ms)):
                lib.bb_wait_released = releasing
                for tick in (0.0, 1.0, 15.625):
                    for late in (0.0, 0.4, 15.6):
                        asked.clear()
                        t.update(now=3.3, tick=tick, late=late)
                        start = read()
                        assert not blobly.wait_released(250)
                        # each slice at most SLICE_MS and none asked past the deadline (a look,
                        # 0, waits for nothing); the wait over within a tick and a late wake of it
                        for at, ms in asked:
                            assert 0 <= ms <= 100 and (ms == 0 or at + ms <= start + 250), (tick, late, asked)
                        assert t["now"] <= 3.3 + 250 + tick + late, (tick, late, asked)
                asked.clear()
                t.update(now=0.0, tick=0.0, late=0.0)
                lib.bb_wait_released = lambda ms: releasing(ms, free_at=3)
                assert blobly.wait_released(None)
                assert [ms for _, ms in asked] == [100, 100, 100], "a wait for ever is not asked in slices"
            lib.bb_wait_released = lambda ms: 7  # an answer this package does not know: not free
            assert not blobly.wait_released(None)
        finally:
            lib.bb_wait_released = real

    def test_a_close_ends_a_wait_on_its_handle(self, tmp_path):
        with blobly.Project(write(tmp_path, "quiet.blobnet", QUIET)) as net:
            q = net.channels.Q
            q.recv(0)
            threading.Timer(0.2, q.close).start()
            t0 = time.monotonic()
            with pytest.raises(blobly.BloblyError):
                q.recv(5000)  # a wait in slices still ends on a close from another thread
            assert time.monotonic() - t0 < 2.0


class TestThreads:
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
                    assert can1.recv(1000) is not None
                except Exception as e:  # any failure on the thread fails the test
                    failures.append(repr(e))
            t = threading.Thread(target=work)
            t.start()
            t.join()
            assert failures == []
            assert (ident[0], 0) in _lib.detached, "the thread was not detached on itself"
