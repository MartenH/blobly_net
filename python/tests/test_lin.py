"""LIN from Python: net.lin on projects/lin-demo (BODY: master, simulating CEM, LSM and RSM on
NormalTable, its frames decoded through dbc/lin_demo.ldf) — tests/lin.lua's cases — and a LIN bus
on an address with no project."""
import os
import textwrap
import threading
import time

import pytest

import blobly
from conftest import REPO, run_python

PROJECT = os.path.join(REPO, "projects", "lin-demo.blobnet")
LDF = os.path.join(REPO, "dbc", "lin_demo.ldf")

pytestmark = pytest.mark.usefixtures("engine")


@pytest.fixture(scope="module")
def net():
    with blobly.Project(PROJECT) as p:
        yield p


@pytest.fixture
def body(net):
    return net.lin.BODY


def test_the_run_lists_its_lin_buses(net):
    assert len(net.lin) == 1 and "BODY" in net.lin and net.lin[0] is net.lin.BODY
    b = net.lin.BODY
    assert (b.address, b.role, b.baud) == ("inproc:body", "master", 19200)
    assert os.path.samefile(b.ldf, LDF)
    assert "CAN1" in net.channels and "BODY" not in net.channels  # LIN is never a channel


def test_frames_arrive_with_their_template_values(body):
    f = body.expect("CEM_Frm2", 500)
    assert (f.id, f.name, f.origin, len(f.data), f.errs, f.event) == (0x02, "CEM_Frm2", "TX-S", 3, frozenset(), "frame")
    assert f.signals == {"CabinTemp": 20.0, "VehicleSpeed": 15.625}  # 120 at 0.5 from -40; 0x0FA at 0.0625
    assert f.raw == {"CabinTemp": 120, "VehicleSpeed": 0x0FA}
    assert 0 < f.t_ms <= blobly.now_ms()
    lsm = body.expect(0x12, 500)
    assert lsm.signals["LSMerror"] == "OK" and lsm.raw["IntTest"] == 0
    assert lsm == blobly.LinFrame(lsm.id, lsm.pid, lsm.data, lsm.errs, lsm.event, lsm.origin, lsm.checksum, lsm.model)


def test_set_changes_what_lsm_sends(body):
    body.set("IntTest", "passed")
    for _ in range(10):
        f = body.expect("LSM_Frm2", 500)
        if f.raw["IntTest"] == 2:
            break
    assert f.signals["IntTest"] == "passed"
    body.set("IntTest", 0, raw=True)
    with pytest.raises(blobly.Refused, match="whole number"):
        body.set("IntTest", 0.5, raw=True)
    with pytest.raises(blobly.Refused, match="no signal `Nope`"):
        body.set("Nope", 1)
    with pytest.raises(TypeError):
        body.set("IntTest", True)


def test_a_schedule_switch_to_fast_table(body):
    body.schedule("FastTable")
    try:
        f = body.expect("RSM_Frm3", 500)
        assert len(f.data) == 8 and f.signals["RSM_Serial"][0] == 0x10
        assert body.expect("LSM_Frm3", 500).signals["LSM_Ident"] == "LSM1"
        assert body.status().schedule == "FastTable"
    finally:
        body.schedule("NormalTable")
    with pytest.raises(blobly.Refused):
        body.schedule("NoSuchTable")


def test_expect_names_what_came_instead(body):
    with pytest.raises(blobly.Timeout, match=r"BODY: no 0x30 within 100 ms; came instead: .*CEM_Frm1 x") as e:
        body.expect(0x30, 100)
    assert e.value.code == -5
    with pytest.raises(blobly.Refused, match="no frame `Nope`"):
        body.expect("Nope", 100)
    with pytest.raises(ValueError, match="0..63"):
        body.expect(64, 100)


def test_sleep_and_wakeup(body):
    assert body.stop_schedule()
    try:
        body.sleep()
        assert body.expect(0x3C, 500).event == "sleep"
        assert body.status().state == "sleep"
        body.wakeup()
        w = body.recv(500)
        while w is not None and w.event != "wakeup":
            w = body.recv(500)
        assert w is not None and w.event == "wakeup" and w.origin == "TX-S"
        assert body.status().state == "active"
    finally:
        body.schedule("NormalTable")
    body.expect("CEM_Frm1", 500)


def test_status_counts_per_id(body):
    body.expect("RSM_Frm2", 500)
    st = body.status()
    assert (st.name, st.address, st.role, st.schedule, st.schedule_running) == ("BODY", "inproc:body", "master",
                                                                                 "NormalTable", True)
    assert st.frames[0x01].count > 0 and st.frames[0x01].name == "CEM_Frm1"
    assert st.frames[0x12].errors == 0 and st.frames[0x12].cadence_ms == pytest.approx(55, abs=15)
    assert st.schedule_sent > 0 and st.schedule_failed == 0
    assert isinstance(st.load, float) and any("event-triggered" in n for n in st.notes)
    assert body.diagnostics().dropped == 0


def test_a_bus_is_kept_across_a_stop_and_a_start(net):
    b = net.lin.BODY
    b.expect("CEM_Frm1", 500)
    net.stop()
    try:
        with pytest.raises(blobly.BloblyError, match="not started") as e:
            b.recv(0)
        assert e.value.code == -3
        with pytest.raises(blobly.BloblyError, match="not started"):
            net.lin
    finally:
        net.start()
    assert net.lin.BODY is b
    assert b.expect("CEM_Frm1", 500).id == 0x01  # a tap on the new run's bus


def test_a_closed_project_bus_taps_the_run_again(net):
    with net.lin.BODY as b:
        b.expect("CEM_Frm1", 500)
    assert net.lin.BODY is b
    assert b.expect("CEM_Frm1", 500).id == 0x01
    b.close()
    net.stop()
    net.start()
    assert net.lin.BODY.expect("CEM_Frm1", 500).id == 0x01


def test_a_bus_on_an_address_needs_no_project():
    with blobly.lin.open("inproc:py_lin", "master", ldf=LDF) as master, \
            blobly.lin.open("inproc:py_lin") as monitor:
        assert (master.role, monitor.role, master.baud) == ("master", "monitor", 0)
        master.header(0x01)
        f = monitor.recv(500)
        assert f is not None and f.id == 0x01 and f.errs == {"no_response"} and f.origin == "TX"
        with pytest.raises(blobly.Refused, match="monitor"):
            monitor.header(0x01)
        with pytest.raises(blobly.Refused):
            blobly.lin.open("inproc:py_lin", "master")  # one master per bus
    with pytest.raises(blobly.BloblyError, match="closed"):
        master.recv(0)
    with pytest.raises(ValueError, match="not an address"):
        blobly.lin.open("BODY")
    with pytest.raises(ValueError, match="master, slave or monitor"):
        blobly.lin.open("inproc:x", "boss")  # type: ignore[arg-type]


def test_a_close_from_another_thread_ends_a_wait():
    bus = blobly.lin.open("inproc:py_lin_quiet")
    got = []

    def wait():
        try:
            bus.recv(None)
        except blobly.BloblyError as e:
            got.append(e)
    t = threading.Thread(target=wait)
    t.start()
    time.sleep(0.1)
    t0 = time.monotonic()
    bus.close()
    t.join(2)
    assert not t.is_alive() and got, "the wait went on after the close"
    assert time.monotonic() - t0 < 0.5


INTERRUPTED = textwrap.dedent("""
    import os, signal, sys, threading, time
    sys.path.insert(0, sys.argv[1])
    import blobly
    sent = []

    def ctrl_c():
        sent.append(time.monotonic())
        if sys.platform == "win32":
            signal.raise_signal(signal.SIGINT)
        else:
            os.kill(os.getpid(), signal.SIGINT)
    with blobly.lin.open("inproc:quiet") as bus:
        threading.Timer(0.3, ctrl_c).start()
        try:
            {"recv": lambda: bus.recv(None), "expect": lambda: bus.expect(1, 3_600_000)}[sys.argv[2]]()
        except KeyboardInterrupt:
            print(f"interrupted {time.monotonic() - sent[0]:.3f} s after Ctrl-C")
""")


@pytest.mark.parametrize("wait", ["recv", "expect"])
def test_ctrl_c_ends_a_long_wait(wait):
    pkg = os.path.dirname(os.path.dirname(os.path.abspath(blobly.__file__)))
    out = run_python("-I", "-c", INTERRUPTED, pkg, wait, timeout=60)
    late = [float(line.split()[1]) for line in out.stdout.splitlines() if line.startswith("interrupted")]
    assert late, out.stdout + out.stderr
    assert late[0] < 0.5, "Ctrl-C waited for the wait to end"
