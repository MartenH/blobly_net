"""blobly.pytest_plugin under pytest: small suites written to a scratch directory and run by pytest
as their own process, as a user runs them. They check that the project comes from the ini file
(relative to it) or from --blobly-project (which wins), that a test hears what arrives from its
start and neither the frames an earlier test left queued nor its handlers or faults, that a test which
stopped the run leaves it started for the next, that the run ends with its module (or with the
session, by blobly_run), that a channel's handle is kept from test to test and what it held read
away, its E2E counter check begun again at each test, that a row which does not open is warned of once or, by blobly_channels, fails each test's
setup, that a failed expectation is a clean failure in pytest's output and in its --junitxml report,
that `diag` takes a node of the system model by its name, that a row is attached elsewhere by
blobly_interfaces or --blobly-interface, and that a run from the repository's root collects."""
import os
import re
import xml.etree.ElementTree as ET

from conftest import INSTALLED, REPO, SIM_DEMO, run_python, write

# the plugin from the package this run tests: the installed wheel, or the source tree (an isolated
# child ignores PYTHONPATH, so the conftest puts it on sys.path)
CONFTEST = ("" if INSTALLED else f"import sys\nsys.path.insert(0, {os.path.join(REPO, 'python')!r})\n") + \
    'pytest_plugins = ["blobly.pytest_plugin"]\n'

# one wire with a SUT that answers 0x101 with 0x102 and a generator sending 0x300 every 20 ms
PROJECT = """project:
  name: plugin test
  version: 8
channels:
  - name: CAN1
    type: can
    interface: inproc:PY_PLUGIN
    simulation:
      - name: SUT
        responses:
          - { request: "0x101", response: "0x102", byte: 0, add: 1 }
    senders:
      - { name: tick, id: "0x300", data: "01", trigger: cyclic, cycle_ms: 20 }
"""

PLUGIN_SUITE = '''import time

import pytest

import blobly

heard = []


def test_a_handler_and_an_answer_left_queued(project, can1):
    project.on_message(can1, None, heard.append)
    can1.send(0x101, b"\\x05")
    time.sleep(0.1)  # the answer queues on this test's handle, and nothing reads it


def test_neither_reaches_the_next_test(project, can1):
    with pytest.raises(blobly.Timeout):
        can1.expect(0x102, timeout_ms=200)
    project.run(200)
    assert heard == [], "the earlier test's handler ran in this one"


def test_a_frame_before_the_first_use_is_kept(can1):
    time.sleep(0.1)  # the generator sends 0x300 every 20 ms
    frame, _ = can1.look()
    assert frame is not None, "the channel was opened at its first use, not as the test began"


def test_a_failed_expectation(can1):
    can1.expect(0x555, timeout_ms=200)


def test_a_test_that_stops_the_run(project):
    project.stop()


def test_the_next_test_finds_it_started(project, can1):
    assert project.started
    can1.send(0x101, b"\\x05")
    assert can1.expect(0x102, timeout_ms=1000).data == b"\\x06"
'''

# runs after the plugin's module: refused (one run per process) unless that module's run ended
OWN_RUN_SUITE = '''import os

import blobly


def test_a_module_that_brings_up_its_own_run():
    with blobly.Project(os.path.join(os.path.dirname(__file__), "suite.blobnet")) as net:
        assert net.channels.CAN1.recv(1000) is not None
'''

# the run a module sees, compared by the next module: the same under blobly_run = session
RUN_SEEN_SUITE = '''import os

import blobly._lib


def test_the_run_it_sees(project):
    os.environ["PY_PLUGIN_RUN"] = str(blobly._lib.state["run"])
'''

RUN_COMPARED_SUITE = '''import os

import blobly._lib


def test_the_same_run_or_another(project):
    same = blobly._lib.state["run"] == int(os.environ["PY_PLUGIN_RUN"])
    assert same == (os.environ["PY_PLUGIN_SAME"] == "1")
'''

# the handle kept from test to test, what it held read away, its UDS clients and J1939 messages let go
KEPT_SUITE = '''import time

import blobly

kept = {}
BAM = [(0x1CECFF00, bytes([0x20, 9, 0, 2, 0xFF, 0xF1, 0xFE, 0x00])),
       (0x1CEBFF00, bytes([1, 1, 2, 3, 4, 5, 6, 7])),
       (0x1CEBFF00, bytes([2, 8, 9, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))]


def send_bam():
    with blobly.open("inproc:PY_PLUGIN") as other:
        for id, data in BAM:
            other.send(id, data, ext=True)


def test_a_leaves_frames_a_client_and_a_j1939_message(can1):
    can1.j1939()
    kept["h"], kept["client"] = can1._h, can1.uds()
    assert kept["client"]._h is not None
    send_bam()
    time.sleep(0.1)  # queued on the handle, and nothing reads it


def test_b_the_handle_is_kept_and_the_rest_let_go(can1):
    assert can1._h == kept["h"], "the channel was closed between the tests"
    assert kept["client"]._h is None, "the earlier test's UDS client kept its connection"
    assert can1.j1939().messages(0) == [], "a J1939 message the earlier test left was read"
    send_bam()
    assert [m.pgn for m in can1.j1939().messages(500)] == [0xFEF1]
'''

# CAN2 names an interface that is nowhere
UNOPENED_PROJECT = PROJECT + """  - name: CAN2
    type: can
    interface: nosuchcan7
"""

UNOPENED_SUITE = '''def test_one(can1):
    pass


def test_two(can1):
    pass
'''

SIM_DEMO_SUITE = '''def test_the_project_is_sim_demo(can2):
    assert can2.iface == "inproc:CAN2"


def test_a_fault_left_armed(project):
    project.fault("CAN1", "SUT", "Powertrain", "drop")


def test_is_not_the_next_tests(can1):
    can1.expect(0x100, timeout_ms=1000)
'''


NODE_SUITE = '''import pytest

import blobly


@pytest.mark.parametrize("diag", ["zone_a"], indirect=True)
def test_a_node_by_its_name(diag):
    assert isinstance(diag, blobly.NodeClient) and diag.node.name == "zone_a"
    assert diag.read("SteerLimit") == 360


@pytest.mark.parametrize("diag", ["edge"], indirect=True)
def test_a_channel_by_its_name(diag):
    assert not isinstance(diag, blobly.NodeClient)


@pytest.mark.parametrize("diag", ["zone_b"], indirect=True)
def test_neither(diag):
    pass
'''


# a LIN bus is tapped afresh for each test: what an earlier test left queued is not read
LIN_SUITE = '''import time

import blobly


def test_a_reads_the_bus(project):
    project.lin.BODY.expect("CEM_Frm1", 500)


def test_b_leaves_frames_queued():
    time.sleep(1.5)


def test_c_reads_nothing_from_before_it(project):
    began = blobly.now_ms()
    f = project.lin.BODY.expect("CEM_Frm1", 500)
    assert f.t_ms > began - 500, (began - f.t_ms)
'''


# the counter a test read last is not what the next test is judged against: test_b's first frame,
# its counter 7 after test_a's 0 and 1, is judged on its CRC alone, as after a drop fault since cleared
E2E_SUITE = '''import blobly.e2e


def test_a_reads_two_frames(e2e, e2e_tap):
    for _ in range(2):
        e2e.messages.BrakeCommand.send(Demand=100)
        e2e_tap.expect(e2e_tap.messages.BrakeCommand, timeout_ms=500, e2e=True)


def test_b_judges_from_its_first_frame(e2e, e2e_tap):
    data = blobly.e2e.p01_protect(bytes(4), data_id=8705, crc_pos=2, counter_pos=3, counter=7)
    e2e.send(0x302, data)
    assert e2e_tap.expect(0x302, timeout_ms=500, e2e=True).data == data
'''


def write_all(d, files):
    for name, text in files.items():
        write(d, name, text)


def pytest_run(*args, **env):
    """pytest as its own process, isolated as this one is, from a scratch working directory."""
    return run_python("-m", "pytest", "-p", "no:cacheprovider", *map(os.fspath, args), env=env)


class TestPlugin:
    def test_a_suite_on_the_plugin(self, tmp_path):
        d = tmp_path
        write_all(d, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = suite.blobnet\n",
                  "suite.blobnet": PROJECT, "test_1_plugin.py": PLUGIN_SUITE,
                  "test_2_own_run.py": OWN_RUN_SUITE})
        junit = d / "report.xml"
        r = pytest_run(d, f"--junitxml={junit}")
        out = r.stdout + r.stderr
        assert r.returncode == 1, out
        assert "1 failed, 6 passed" in out
        assert re.search(r"FAILED \S*test_1_plugin\.py::test_a_failed_expectation", out)
        expected = "CAN1: expected a frame 0x555 within 200 ms; "
        assert re.search(re.escape(expected) + r"\d+ other frames came: \d+ of 0x300", out)
        # the failure points at the test's line; no frame of the package is shown
        assert '>       can1.expect(0x555, timeout_ms=200)' in out
        assert not re.search(r"project\.py:\d+", out)
        failures = [f.get("message") for f in ET.parse(junit).iter("failure")]
        assert len(failures) == 1, failures
        assert expected in failures[0]

    def test_one_run_per_module_or_per_session(self, tmp_path):
        d = tmp_path
        write_all(d, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = suite.blobnet\n",
                      "suite.blobnet": PROJECT, "test_1_seen.py": RUN_SEEN_SUITE,
                      "test_2_compared.py": RUN_COMPARED_SUITE})
        r = pytest_run(d, PY_PLUGIN_SAME="0")
        assert r.returncode == 0, r.stdout + r.stderr
        r = pytest_run(d, "--blobly-run=session", PY_PLUGIN_SAME="1")
        assert r.returncode == 0, r.stdout + r.stderr
        write(d, "pytest.ini", "[pytest]\nblobly_project = suite.blobnet\nblobly_run = session\n")
        r = pytest_run(d, PY_PLUGIN_SAME="1")
        assert r.returncode == 0, r.stdout + r.stderr
        r = pytest_run(d, "--blobly-run=module", PY_PLUGIN_SAME="0")  # the command line wins
        assert r.returncode == 0, r.stdout + r.stderr
        # a module bringing up a project of its own is refused while the session's run holds the process
        write(d, "test_3_own_run.py", OWN_RUN_SUITE)
        r = pytest_run(d, PY_PLUGIN_SAME="1")
        assert r.returncode == 1, r.stdout + r.stderr
        assert "1 failed, 2 passed" in r.stdout + r.stderr
        r = pytest_run(d, "--blobly-run=class")
        assert r.returncode == 4, r.stdout + r.stderr
        assert "blobly: --blobly-run is 'class'; it is module or session" in r.stdout + r.stderr

    def test_a_channel_is_drained_not_closed(self, tmp_path):
        write_all(tmp_path, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = suite.blobnet\n",
                             "suite.blobnet": PROJECT, "test_kept.py": KEPT_SUITE})
        r = pytest_run(tmp_path)
        assert r.returncode == 0, r.stdout + r.stderr

    def test_a_row_that_does_not_open(self, tmp_path):
        d = tmp_path
        write_all(d, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = suite.blobnet\n",
                      "suite.blobnet": UNOPENED_PROJECT, "test_it.py": UNOPENED_SUITE})
        said = "blobly: CAN2 (nosuchcan7) did not open: "
        r = pytest_run(d)  # lazy: the tests run, and one warning per run names the row
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert "2 passed, 1 warning" in out, out
        assert out.count(said) == 1, out
        r = pytest_run(d, "-o", "blobly_channels=required")  # every test's setup errors, on one line
        out = r.stdout + r.stderr
        assert r.returncode == 1, out
        assert "2 errors" in out, out
        assert len(re.findall("^" + re.escape(said), out, re.M)) == 2, out  # the message alone, no traceback
        assert not re.search(r"pytest_plugin\.py:\d+", out), out
        r = pytest_run(d, "-o", "blobly_channels=eager")
        assert r.returncode == 4, r.stdout + r.stderr
        assert "blobly: blobly_channels in the ini file is 'eager'; it is lazy or required" in r.stdout + r.stderr

    def test_where_the_project_comes_from(self, tmp_path):
        d = tmp_path
        write_all(d, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = missing.blobnet\n",
                  "test_it.py": SIM_DEMO_SUITE})
        r = pytest_run(d)
        assert r.returncode == 4, r.stdout + r.stderr  # pytest's usage error
        assert (f"no Blobly Net project at {d / 'missing.blobnet'} (from blobly_project in the ini file)"
                in r.stdout + r.stderr)
        r = pytest_run(d, f"--blobly-project={SIM_DEMO}")
        assert r.returncode == 0, r.stdout + r.stderr
        r = pytest_run(d, "--blobly-project=", "-o", f"blobly_project={SIM_DEMO}")
        assert r.returncode == 4, r.stdout + r.stderr  # an empty override is not the ini's
        assert "(from --blobly-project)" in r.stdout + r.stderr
        r = pytest_run(d, "-o", "blobly_project=")
        assert r.returncode == 4, r.stdout + r.stderr
        assert ("no Blobly Net project: give --blobly-project=PATH, or set blobly_project in the ini file"
                in r.stdout + r.stderr)
        assert pytest_run(d, "-o", "blobly_project=", "--help").returncode == 0
        assert pytest_run(d, "--help").returncode == 0, "help needs no project that loads"
        r = pytest_run(d, f"--blobly-project={SIM_DEMO}", BLOBLY_LIB=os.fspath(d / "no-such-library"))
        assert r.returncode == 4, r.stdout + r.stderr  # a usage error, not an INTERNALERROR
        assert "libblobly not found" in r.stdout + r.stderr

    def test_a_fixture_per_channel_named_after_it(self, tmp_path):
        rows = ["CAN-1", "2nd bus", "Body Bus", "body-bus", "class", "project", "_blobly_run", "__slots__",
                "pytest_configure", "tmp_path"]
        write_all(tmp_path, {
            "conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = names.blobnet\n",
            "names.blobnet": "project:\n  name: names\n  version: 8\nchannels:\n" + "".join(
                f"  - name: {n}\n    type: can\n    interface: inproc:PY_NAMES_{i}\n" for i, n in enumerate(rows)),
            "test_names.py": "def test_names(can_1, _2nd_bus, __slots__, pytest_configure, tmp_path, project):\n"
                             "    assert tmp_path.is_dir(), 'a channel took pytest\\'s tmp_path'\n"
                             "    assert (can_1.name, _2nd_bus.name) == ('CAN-1', '2nd bus')\n"
                             "    assert (__slots__.name, pytest_configure.name) == ('__slots__', "
                             "'pytest_configure')\n"})
        r = pytest_run(tmp_path)
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        # one warning names every channel that got no fixture, and why
        assert ("blobly: no fixture for 'Body Bus', 'body-bus' (as 'body_bus'); 'class' (as 'class'); "
                "'project' (as 'project'); '_blobly_run' (as '_blobly_run'); 'tmp_path' (as 'tmp_path')") in out

    def test_a_lin_bus_starts_each_test_fresh(self, tmp_path):
        write_all(tmp_path, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\n", "test_lin.py": LIN_SUITE})
        lin_demo = os.path.join(REPO, "projects", "lin-demo.blobnet")
        r = pytest_run(tmp_path, f"--blobly-project={lin_demo}")
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert "3 passed" in out, out

    def test_the_e2e_check_begins_at_each_test(self, tmp_path):
        write_all(tmp_path, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\n", "test_e2e.py": E2E_SUITE})
        e2e_demo = os.path.join(REPO, "projects", "e2e-demo.blobnet")
        r = pytest_run(tmp_path, f"--blobly-project={e2e_demo}")
        out = r.stdout + r.stderr
        assert r.returncode == 0, out
        assert "2 passed" in out, out

    def test_diag_on_a_node_of_the_system_model(self, tmp_path):
        # the ini makes tmp_path the run's root, so the child does not look above it into the
        # temp folder other workers are deleting from
        write_all(tmp_path, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\n", "test_node.py": NODE_SUITE})
        described = os.path.join(REPO, "projects", "described-ecu-demo", "described-ecu-demo.blobnet")
        r = pytest_run(tmp_path, f"--blobly-project={described}")
        out = r.stdout + r.stderr
        assert r.returncode == 1, out
        assert "1 error, 2 passed" in out or "2 passed, 1 error" in out, out
        assert "the nodes: zone_a" in out

    def test_a_row_attached_elsewhere_by_the_ini_or_the_command_line(self, tmp_path):
        write_all(tmp_path, {
            "conftest.py": CONFTEST, "suite.blobnet": PROJECT,
            "pytest.ini": "[pytest]\nblobly_project = suite.blobnet\nblobly_interfaces =\n    CAN1=inproc:PY_IFACE_INI\n",
            "test_iface.py": "import os\n\ndef test_where(can1):\n    assert can1.iface == os.environ['WANT']\n"
                             "    can1.send(0x101, b'\\x05')\n    assert can1.expect(0x102, timeout_ms=2000).data[0] == 6\n"})
        r = pytest_run(tmp_path, WANT="inproc:PY_IFACE_INI")
        assert r.returncode == 0, r.stdout + r.stderr
        assert "CAN1 on inproc:PY_IFACE_INI" in r.stdout
        r = pytest_run(tmp_path, "--blobly-interface=CAN1=inproc:PY_IFACE_CLI", WANT="inproc:PY_IFACE_CLI")
        assert r.returncode == 0, r.stdout + r.stderr
        r = pytest_run(tmp_path, "--blobly-interface=CAN9=inproc:x", WANT="")
        assert r.returncode == 4, r.stdout + r.stderr  # a usage error naming the rows
        assert 'the project has no row named "CAN9" (its rows: "CAN1")' in r.stdout + r.stderr
        r = pytest_run(tmp_path, "--blobly-interface=CAN1", WANT="")
        assert r.returncode == 4, r.stdout + r.stderr
        assert "'CAN1' (from --blobly-interface) is not NAME=IFACE" in r.stdout + r.stderr
        r = pytest_run(tmp_path, "--blobly-interface=CAN1=", WANT="")
        assert r.returncode == 4, r.stdout + r.stderr  # the engine's own refusal
        assert 'interface override "CAN1=": gives no interface' in r.stdout + r.stderr

    def test_a_run_from_the_repository_root_leaves_the_examples_suite_out(self):
        # its conftest's pytest_plugins is refused below a run's root, so python/conftest.py
        # leaves python/examples to its own runs (test_examples.py)
        r = pytest_run("--collect-only", "-q", REPO)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "test_pytest_plugin.py::TestPlugin" in r.stdout
        assert "test_sim_demo.py" not in r.stdout
