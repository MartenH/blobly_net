"""A bus opened by its address with no project row (blobly.open), the interfaces present
(blobly.interfaces, blobly.discover_cansub) and Vector assignment (blobly.vector). Vector and CANsub
hardware are on no CI runner: what runs here is the listing's shape, the refusals by name, and on
Linux the Vector calls refused as Windows-only; the rules themselves are V tests
(blobly/transport/interfaces_test.v, vector_names_test.v)."""
import os
import sys
import textwrap
import threading
import time

import pytest

import blobly
from blobly import _lib, vector
from conftest import SIM_DEMO, write

pytestmark = pytest.mark.usefixtures("engine")

KINDS = {"socketcan", "vcan", "pcan", "kvaser", "vector", "cansub", "bridge", "udp", "inproc"}


def test_two_buses_by_address_exchange_frames_with_no_project():
    with blobly.open("inproc:PY_IFACE_A") as a, blobly.open("inproc:PY_IFACE_A") as b:
        assert isinstance(a, blobly.Bus) and a.iface == "inproc:PY_IFACE_A"
        a.send(0x123, b"\x01\x02")
        got = b.expect(0x123, 1000)
        assert got.data == b"\x01\x02" and got.t_ms is not None
        assert a.recv(0) is None, "a bus never hears its own sends"
        a.send(0x1ABCDE, b"\x07", ext=True)
        assert b.recv(1000) == blobly.Frame(0x1ABCDE, b"\x07", ext=True)
        assert a.health() == "", "a software bus has no controller ladder"
        assert a.load().frames == 2 and a.load().nominal == 500000
        assert b.diagnostics().dropped == 0


def test_an_expect_on_a_bus_says_what_came_instead():
    with blobly.open("inproc:PY_IFACE_B") as a, blobly.open("inproc:PY_IFACE_B") as b:
        a.send(0x200, b"")
        with pytest.raises(blobly.Timeout, match="0x200"):
            b.expect(0x201, 100)


def test_a_closed_bus_refuses_and_a_close_from_another_thread_ends_a_wait():
    bus = blobly.open("inproc:PY_IFACE_C")
    threading.Timer(0.1, bus.close).start()
    t = time.monotonic()
    with pytest.raises(blobly.BloblyError):
        bus.recv(5000)
    assert time.monotonic() - t < 2
    with pytest.raises(blobly.BloblyError, match="closed"):
        bus.send(0x1, b"")
    bus.close()  # twice is nothing


@pytest.mark.parametrize("bad, kind", [("", TypeError), (None, TypeError), ("inproc:A\0B", ValueError)])
def test_an_address_is_a_string_without_a_nul(bad, kind):
    with pytest.raises(kind):
        blobly.open(bad)


@pytest.mark.parametrize("endpoint", ["doip:127.0.0.1:13400", "someip:0.0.0.0:30490"])
def test_an_ethernet_endpoint_is_refused_by_name(endpoint):
    with pytest.raises(blobly.BloblyError, match="carries no CAN frames"):
        blobly.open(endpoint)


def test_a_listen_only_wire_of_the_loaded_project_refuses_a_by_address_send(tmp_path):
    path = write(tmp_path, "silent.blobnet", textwrap.dedent("""\
        project:
          name: silent
          version: 8
        channels:
          - name: S
            type: can
            interface: inproc:PY_IFACE_SILENT
            listen_only: true
        """))
    bus = blobly.open("inproc:PY_IFACE_SILENT")
    try:
        bus.send(0x100, b"\x00")
        blobly.Project(path).load()
        with pytest.raises(blobly.BloblyError, match="listen-only"):
            bus.send(0x100, b"\x00")
        with blobly.open("inproc:PY_IFACE_SILENT") as late:
            with pytest.raises(blobly.BloblyError, match="listen-only"):
                late.send(0x100, b"\x00")
    finally:
        bus.close()
        blobly.Project(SIM_DEMO).load()  # its policy, for the tests after this one


@pytest.mark.skipif(not os.path.exists("/sys/class/net/vcan0"), reason="no vcan0 here")
def test_vcan0_opens_by_address_and_is_listed():
    assert any(i.address == "vcan0" and i.kind == "vcan" for i in blobly.interfaces())
    with blobly.open("vcan0") as a, blobly.open("vcan0") as b:
        a.send(0x321, b"\xAA")
        assert b.expect(0x321, 1000).data == b"\xAA"


def test_the_listing_is_well_formed_rows():
    rows = blobly.interfaces()
    assert rows, "the software buses are always there"
    for i in rows:
        assert isinstance(i, blobly.Interface)
        assert i.address and i.kind in KINDS and i.description
        assert i.fd in (True, False, None)
        assert isinstance(i.bitrate, int) and i.bitrate >= 0
        assert isinstance(i.virtual, bool) and isinstance(i.state, str)
        if i.kind != "vector":
            assert i.state == ""
    assert len({i.address for i in rows}) == len(rows), "one row per address"
    sim = next(i for i in rows if i.kind == "inproc")
    assert sim.virtual and sim.fd is True
    with blobly.open(sim.address) as bus:  # a listed address opens
        bus.send(0x1, b"")


@pytest.mark.parametrize("window", [0, -1, 10001])
def test_a_cansub_browse_window_is_bounded(window):
    with pytest.raises(blobly.Refused, match="1 to 10000 ms"):
        blobly.discover_cansub(window)


def test_a_cansub_browse_waits_its_window_and_lists_rows():
    t = time.monotonic()
    try:
        rows = blobly.discover_cansub(200)
    except blobly.Refused as e:  # no network interface could be asked: said, not "nothing attached"
        pytest.skip(str(e))
    assert time.monotonic() - t < 2
    for i in rows:
        assert i.kind == "cansub" and i.address.startswith("cansub:") and i.description


@pytest.mark.skipif(sys.platform == "win32", reason="Linux has no Vector driver")
def test_on_linux_vector_is_refused_as_windows_only():
    assert vector.driver() == "the Vector XL backend is Windows-only"
    assert vector.assignments() == []
    with pytest.raises(blobly.Refused, match="Windows-only"):
        vector.slot(1)
    hw = vector.VectorHardware("VN1630A Channel 1", "", 57, 0, 0, 0, 500000, 0, True, True, True, False, False)
    with pytest.raises(blobly.Refused, match="Windows-only"):
        vector.assign(1, hw, create=True)


def test_vector_arguments_are_checked():
    with pytest.raises(TypeError):
        vector.slot("1")  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        vector.assign(1, "VN1630A")  # type: ignore[arg-type]
    if vector.driver() is None:  # a Windows bench with the driver
        with pytest.raises(blobly.Refused, match="1 to 64"):
            vector.slot(65)


def test_a_freed_listing_is_gone():
    lib = _lib.lib()
    listing = _lib.check(lib.bb_ifaces())
    assert _lib.check(lib.bb_listing_count(listing)) > 0
    _lib.check(lib.bb_listing_free(listing))
    assert lib.bb_listing_count(listing) == _lib.BB_ERR_HANDLE
