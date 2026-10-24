"""blobly.pytest_plugin under pytest: small suites written to a scratch directory and run by pytest
as their own process, as a user runs them. They check that the project comes from the ini file
(relative to it) or from --blobly-project (which wins), that a test hears what arrives from its
start and neither the frames an earlier test left queued nor its handlers or faults, that a test which
stopped the run leaves it started for the next, that the run ends with its module, that a failed expectation is a clean failure in
pytest's output and in its --junitxml report, that `diag` takes a node of the system model by its
name, and that a run from the repository's root collects."""
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

    def test_diag_on_a_node_of_the_system_model(self, tmp_path):
        write_all(tmp_path, {"conftest.py": CONFTEST, "test_node.py": NODE_SUITE})
        described = os.path.join(REPO, "projects", "described-ecu-demo", "described-ecu-demo.blobnet")
        r = pytest_run(tmp_path, f"--blobly-project={described}")
        out = r.stdout + r.stderr
        assert r.returncode == 1, out
        assert "1 error, 2 passed" in out or "2 passed, 1 error" in out, out
        assert "the nodes: zone_a" in out

    def test_a_run_from_the_repository_root_leaves_the_examples_suite_out(self):
        # its conftest's pytest_plugins is refused below a run's root, so python/conftest.py
        # leaves python/examples to its own runs (test_examples.py)
        r = pytest_run("--collect-only", "-q", REPO)
        assert r.returncode == 0, r.stdout + r.stderr
        assert "test_pytest_plugin.py::TestPlugin" in r.stdout
        assert "test_sim_demo.py" not in r.stdout
