"""The newest frame per id and kind (Channel.latest, Bus.latest), a signal's value in it
(Channel.value), and net.wait reading every open channel while time passes."""
import math
import time
from unittest import mock

import pytest

import blobly
from blobly import project
from conftest import SIM_DEMO, write

pytestmark = pytest.mark.usefixtures("engine")

DBC = '''VERSION ""

BU_: A

BO_ 291 Door: 2 A
 SG_ Locked : 0|8@1+ (1,0) [0|255] "" A
 SG_ Mode M : 8|8@1+ (1,0) [0|255] "" A
'''

# two rows on one wire: X reads what Y sends
TWO_ROWS = """project:
  name: latest
  version: 8
channels:
  - name: X
    type: can
    interface: inproc:PY_LATEST
    databases:
      - latest.dbc
  - name: Y
    type: can
    interface: inproc:PY_LATEST
"""


@pytest.fixture
def two_rows(tmp_path):
    write(tmp_path, "latest.dbc", DBC)
    path = write(tmp_path, "latest.blobnet", TWO_ROWS)
    with blobly.Project(path) as net:
        x, y = net.channels.X, net.channels.Y
        x.look()  # X's handle is open before Y sends
        yield net, x, y


class TestLatest:
    def test_the_newest_frame_of_an_id_and_kind_as_of_the_call(self, two_rows):
        net, x, y = two_rows
        assert x.latest(0x123) is None
        y.send(0x123, b"\x01")
        y.send(0x123, b"\x02")
        y.send(0x123, b"\x03", ext=True)
        assert x.latest(0x123, ext=False) == blobly.Frame(0x123, b"\x02")
        assert x.latest(0x123, ext=True) == blobly.Frame(0x123, b"\x03", ext=True)
        assert x.latest(0x123) == blobly.Frame(0x123, b"\x03", ext=True), "either kind: the newer"
        assert x.recv(0) == blobly.Frame(0x123, b"\x01"), "asking reads nothing off the channel"
        f = x.latest(0x123, ext=False)
        assert f.t_ms is not None and f.t_ms <= blobly.now_ms()

    def test_it_stays_current_while_nothing_reads_the_channel(self, two_rows):
        net, x, y = two_rows
        # more than the handle's queue holds (inproc: 8192), with nothing reading it meanwhile
        for i in range(9000):
            y.send(0x210, i.to_bytes(2, "little"))
        assert x.latest(0x210).data == (8999).to_bytes(2, "little")

    def test_what_the_channel_sends_is_not_kept(self, two_rows):
        net, x, y = two_rows
        x.send(0x220, b"\x01")
        y.send(0x221, b"\x02")
        assert x.latest(0x221) is not None
        assert x.latest(0x220) is None, "the channel heard its own send"
        y.send(0x220, b"\x01")
        assert x.latest(0x220) == blobly.Frame(0x220, b"\x01"), "the same frame from another node"

    def test_forgetting_takes_what_was_queued_before_it_too(self, two_rows):
        net, x, y = two_rows
        for i in range(50):
            y.send(0x240 + i, b"\x01")
            x._forget_latest()
            assert x.latest(0x240 + i) is None, "a frame sent before the clear outlived it"

    def test_the_plugin_forgets_what_an_earlier_test_saw(self, two_rows):
        net, x, y = two_rows
        y.send(0x230, b"\x01")
        assert x.latest(0x230) is not None
        x._forget_latest()
        assert x.latest(0x230) is None
        y.send(0x230, b"\x02")
        assert x.latest(0x230).data == b"\x02"

    def test_every_read_path_fills_it(self, two_rows):
        net, x, y = two_rows
        y.send(0x200, b"\x0a")
        assert x.recv(1000) == blobly.Frame(0x200, b"\x0a")
        y.send(0x201, b"\x0b")
        x.expect(0x201, 1000)
        got = []
        net.on_message(x, 0x202, got.append)
        y.send(0x202, b"\x0c")
        deadline = time.monotonic() + 5
        while not got and time.monotonic() < deadline:
            net.run(50)
        assert got
        assert [x.latest(i).data for i in (0x200, 0x201, 0x202)] == [b"\x0a", b"\x0b", b"\x0c"]

    def test_a_message_and_its_signal(self, two_rows):
        net, x, y = two_rows
        door = x.messages.Door
        assert x.latest(door) is None
        assert x.value(door, "Locked") is None
        y.send(door.id, door.encode(Locked=5, Mode=1).data)
        y.send(door.id, door.encode(Locked=7, Mode=1).data)
        assert x.value("Door", "Locked") == 7.0
        assert x.value(door, door.signals.Mode) == 1.0
        assert x.latest(door).data == door.encode(Locked=7, Mode=1).data
        with pytest.raises(TypeError, match="value: a signal is a Signal or its name"):
            x.value(door, 3)
        with pytest.raises(TypeError, match="leave ext out"):
            x.latest(door, ext=False)

    def test_a_closed_handle_forgets_its_frames(self, two_rows):
        net, x, y = two_rows
        y.send(0x300, b"\x01")
        assert x.latest(0x300) is not None
        x.close()
        assert x.latest(0x300) is None

    def test_a_bus_by_address_has_one_too(self):
        with blobly.open("inproc:PY_LATEST_BUS") as a, blobly.open("inproc:PY_LATEST_BUS") as b:
            a.look()
            b.send(0x10, b"\x01")
            b.send(0x10, b"\x02")
            assert a.latest(0x10) == blobly.Frame(0x10, b"\x02")

    def test_a_bus_faster_than_its_reader_still_answers(self):
        clock = [0.0]
        ch = blobly.Channel(None, 0, "X", 0)  # its reads are the fake below; no library behind it
        ch._handle = lambda: 0
        looks = []

        def receive(ms, h=None):  # a frame at every look, each look costing 1 ms
            looks.append(ms)
            clock[0] += 1
            f = blobly.Frame(0x100, bytes([len(looks) % 256]), t_ms=clock[0])
            ch._latest[(f.id, f.ext)] = f
            return f, False
        ch._receive = receive
        with mock.patch.object(project, "monotonic_ms", lambda: clock[0]):
            f = ch.latest(0x100)
        assert len(looks) == project.CATCH_UP_MS
        assert set(looks) == {0}, "nothing waited for: only what is queued"
        assert f.t_ms == clock[0]

    def test_a_remote_frame_does_not_replace_the_data(self):
        fake = FakeLib([blobly.Frame(0x123, b"\x07"), blobly.Frame(0x123, rtr=True)])
        bus = fake_bus()
        with mock.patch.object(project._lib, "lib", lambda: fake):
            bus.look()
            bus.look()
            assert bus.latest(0x123) == blobly.Frame(0x123, b"\x07")

    def test_a_frame_read_while_another_thread_closes_is_forgotten_with_the_handle(self):
        bus = fake_bus()
        # the close finishes while the receive is inside the library, which still hands it a frame
        fake = FakeLib([blobly.Frame(0x300, b"\x01")], during_recv=bus.close)
        with mock.patch.object(project._lib, "lib", lambda: fake):
            assert bus._receive(20, 1)[0] == blobly.Frame(0x300, b"\x01")
        assert bus._latest == {}


class FakeLib:
    """bb_bus_recv handing out `frames` one per call (then nothing); `during_recv` called inside
    the first receive, before its frame is returned."""

    def __init__(self, frames, during_recv=None):
        self.frames, self.during_recv = list(frames), during_recv

    def bb_bus_recv(self, h, ms, ref):
        if self.during_recv is not None:
            hook, self.during_recv = self.during_recv, None
            hook()
        if not self.frames:
            return project._lib.BB_NONE
        fr, f = self.frames.pop(0), ref._obj
        f.id, f.ext, f.rtr, f.len = fr.id, int(fr.ext), int(fr.rtr), fr.length
        f.data[:len(fr.data)] = fr.data
        return 0

    def bb_bus_close(self, h):
        return 0


def fake_bus():
    """A Bus whose library is FakeLib: no library behind it, so no newest-frame view either."""
    bus = object.__new__(blobly.Bus)
    bus.name, bus._h, bus._latest, bus._watch = "fake", 1, {}, None
    return bus


class TestWait:
    def test_every_open_channel_is_read_and_handlers_run(self, two_rows):
        net, x, y = two_rows
        y.send(0x400, b"\x01")
        net.wait(50)
        assert x.recv(0) is None, "wait read the open channel nobody named"
        assert x._latest[(0x400, False)] == blobly.Frame(0x400, b"\x01")
        heard = []
        net.on_message(x, 0x401, heard.append)
        y.send(0x401, b"\x02")
        net.wait(50)
        assert heard == [blobly.Frame(0x401, b"\x02")]

    def test_time_passes_and_the_duration_is_checked(self, two_rows):
        net, x, y = two_rows
        x.close()  # nothing open: a sleep
        t0 = time.monotonic()
        net.wait(60)
        assert (time.monotonic() - t0) * 1000 >= 55  # a coarse clock may read a little short
        for bad in (math.nan, -1, None):
            with pytest.raises((ValueError, TypeError), match="wait"):
                net.wait(bad)


class TestOnSimDemo:
    def test_a_cyclic_value_is_current_after_a_wait(self, sim_demo):
        can1 = sim_demo.channels.CAN1
        pt = can1.messages.Powertrain
        can1.look()  # its handle open
        sim_demo.wait(350)  # Powertrain every 100 ms
        f = can1.latest(pt)
        assert f is not None and blobly.now_ms() - f.t_ms < 300
        assert 1 <= can1.value(pt, "Gear") <= 6

    def test_a_cyclic_value_is_current_after_a_sleep_with_no_read(self, sim_demo):
        can1 = sim_demo.channels.CAN1
        pt = can1.messages.Powertrain
        can1.look()  # its handle open, and with it the library's reader
        time.sleep(0.35)  # nothing reads can1 meanwhile
        assert can1._watch == can1._h, "latest answers from the library's reader"
        f = can1.latest(pt)
        assert f is not None and blobly.now_ms() - f.t_ms < 150, "Powertrain comes every 100 ms"
        assert can1.recv(0) is not None, "latest read the frames queued during the sleep off the channel"
