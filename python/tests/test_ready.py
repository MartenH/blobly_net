"""Project.wait_ready: start() returns before the run's loops have opened their buses; wait_ready
waits for them and names every one that failed."""

import threading

import pytest

import blobly
from blobly import _lib
from conftest import SIM_DEMO, write

pytestmark = pytest.mark.usefixtures("engine")

# a row on an interface that does not exist, and generators on one that does: one whose frames the
# wire refuses, one that sends, one that opens only at its first fire
NOT_UP = """project:
  name: not-up
  version: 8
channels:
  - name: Gone
    type: can
    interface: nosuchcan631
    simulation:
      - name: SUT
  - name: Here
    type: can
    interface: inproc:PY_READY
    senders:
      - name: Long
        id: "0x321"
        data: 01 02 03 04 05 06 07 08 09
        trigger: cyclic
        cycle_ms: 10
      - name: Ok
        id: "0x322"
        data: 01
        trigger: cyclic
        cycle_ms: 10
      - name: Later
        id: "0x323"
        data: 01
        trigger: manual
"""


def test_every_loop_of_sim_demo_comes_up():
    net = blobly.Project(SIM_DEMO)
    with pytest.raises(blobly.BloblyError) as e:
        net.wait_ready(0)
    assert e.value.code == _lib.BB_ERR_STATE
    with net:
        assert net.wait_ready(5000) is None


def test_the_loops_that_failed_are_named(tmp_path, capfd):
    net = blobly.Project(write(tmp_path, "not_up.blobnet", NOT_UP))
    with net:
        with pytest.raises(blobly.BloblyError) as e:
            net.wait_ready(5000)
    assert type(e.value) is blobly.BloblyError and e.value.code == _lib.BB_ERR
    lines = str(e.value).splitlines()
    assert lines[0] == "3 of 4 not up:", lines
    assert lines[1].startswith("  Gone: simulated nodes: cannot open nosuchcan631"), lines
    assert lines[2].startswith("  Gone: UDS server: cannot open nosuchcan631"), lines
    assert lines[3].startswith('  Here: generator "Long": ') and "classic CAN frame" in lines[3], lines
    assert "Later" not in str(e.value)  # opens at its first fire: not waited for
    assert "Gone: simulated nodes: cannot open" in capfd.readouterr().err  # and said as it failed


def test_the_wait_leaves_the_state_lock_free(monkeypatch):
    lib = _lib.lib()
    real = lib.bb_wait_ready
    free = []

    def spy(part):  # whether another thread could take the state lock while the library waits
        def probe():
            took = _lib.state_lock.acquire(blocking=False)
            free.append(took)
            if took:
                _lib.state_lock.release()
        t = threading.Thread(target=probe)
        t.start()
        t.join()
        return real(part)

    net = blobly.Project(SIM_DEMO)
    with net:
        monkeypatch.setattr(lib, "bb_wait_ready", spy)
        assert net.wait_ready(5000) is None
    assert free and all(free), free


def test_a_wait_across_a_stop_and_start_is_not_the_new_runs(monkeypatch):
    lib = _lib.lib()
    real = lib.bb_wait_ready
    other = blobly.Project(SIM_DEMO)

    def restart(part):  # another thread stops this run and starts another before the wait
        def swap():
            net.stop()
            other.start()
        t = threading.Thread(target=swap)
        t.start()
        t.join()
        return real(part)

    net = blobly.Project(SIM_DEMO)
    net.start()
    try:
        monkeypatch.setattr(lib, "bb_wait_ready", restart)
        with pytest.raises(blobly.BloblyError) as e:
            net.wait_ready(5000)
        assert e.value.code == _lib.BB_ERR_STATE
    finally:
        net.stop()
        other.stop()
