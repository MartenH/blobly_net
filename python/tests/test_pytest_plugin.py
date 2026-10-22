"""blobly.pytest_plugin under pytest: small suites written to a scratch directory and run by pytest
as their own process, as a user runs them. They check that the project comes from the ini file
(relative to it) or from --blobly-project (which wins), that a test hears what arrives from its
start and neither the frames an earlier test left queued nor its handlers or faults, that a test which
stopped the run leaves it started for the next, that the run ends with its module, that a failed expectation is a clean failure in
pytest's output and in its --junitxml report, and that a run from the repository's root collects.

pytest is not a dependency of the package: these are skipped where it is missing.
scripts/python_tests.py, which CI runs, installs it, so there they run."""
import os
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from importlib.util import find_spec

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")
INSTALLED = bool(os.environ.get("BLOBLY_TEST_INSTALLED"))

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


def write(d, files):
    for name, text in files.items():
        with open(os.path.join(d, name), "w", encoding="utf-8") as f:
            f.write(text)


def pytest_run(*args, **env_overrides):
    """pytest as its own process, isolated as this one is, from a scratch working directory."""
    env = dict(os.environ, **env_overrides)
    if env.get("BLOBLY_LIB"):
        env["BLOBLY_LIB"] = os.path.abspath(env["BLOBLY_LIB"])  # the child's directory is not ours
    flags = ["-B"] + (["-I"] if sys.flags.isolated else [])
    with tempfile.TemporaryDirectory() as cwd:
        return subprocess.run([sys.executable, *flags, "-m", "pytest", "-p", "no:cacheprovider", *args], cwd=cwd,
                              env=env, capture_output=True, text=True, encoding="utf-8", errors="replace",
                              timeout=120)


@unittest.skipIf(find_spec("pytest") is None, "pytest is not installed")
class TestPlugin(unittest.TestCase):
    def test_a_suite_on_the_plugin(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = suite.blobnet\n",
                      "suite.blobnet": PROJECT, "test_1_plugin.py": PLUGIN_SUITE,
                      "test_2_own_run.py": OWN_RUN_SUITE})
            junit = os.path.join(d, "report.xml")
            r = pytest_run(d, f"--junitxml={junit}")
            out = r.stdout + r.stderr
            self.assertEqual(r.returncode, 1, out)
            self.assertIn("1 failed, 6 passed", out)
            self.assertRegex(out, r"FAILED \S*test_1_plugin\.py::test_a_failed_expectation")
            expected = "CAN1: expected a frame 0x555 within 200 ms; "
            self.assertRegex(out, re.escape(expected) + r"\d+ other frames came: \d+ of 0x300")
            # the failure points at the test's line; no frame of the package is shown
            self.assertIn('>       can1.expect(0x555, timeout_ms=200)', out)
            self.assertNotRegex(out, r"project\.py:\d+")
            failures = [f.get("message") for f in ET.parse(junit).iter("failure")]
            self.assertEqual(len(failures), 1, failures)
            self.assertIn(expected, failures[0])

    def test_where_the_project_comes_from(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = missing.blobnet\n",
                      "test_it.py": SIM_DEMO_SUITE})
            r = pytest_run(d)
            self.assertEqual(r.returncode, 4, r.stdout + r.stderr)  # pytest's usage error
            self.assertIn(f"no Blobly Net project at {os.path.join(d, 'missing.blobnet')} (from "
                          "blobly_project in the ini file)", r.stdout + r.stderr)
            r = pytest_run(d, f"--blobly-project={SIM_DEMO}")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            r = pytest_run(d, "--blobly-project=", "-o", f"blobly_project={SIM_DEMO}")
            self.assertEqual(r.returncode, 4, r.stdout + r.stderr)  # an empty override is not the ini's
            self.assertIn("(from --blobly-project)", r.stdout + r.stderr)
            r = pytest_run(d, "-o", "blobly_project=")
            self.assertEqual(r.returncode, 4, r.stdout + r.stderr)
            self.assertIn("no Blobly Net project: give --blobly-project=PATH, or set blobly_project in the "
                          "ini file", r.stdout + r.stderr)
            self.assertEqual(pytest_run(d, "-o", "blobly_project=", "--help").returncode, 0)
            self.assertEqual(pytest_run(d, "--help").returncode, 0, "help needs no project that loads")
            r = pytest_run(d, f"--blobly-project={SIM_DEMO}", BLOBLY_LIB=os.path.join(d, "no-such-library"))
            self.assertEqual(r.returncode, 4, r.stdout + r.stderr)  # a usage error, not an INTERNALERROR
            self.assertIn("libblobly not found", r.stdout + r.stderr)

    def test_a_fixture_per_channel_named_after_it(self):
        with tempfile.TemporaryDirectory() as d:
            rows = ["CAN-1", "2nd bus", "Body Bus", "body-bus", "class", "project", "_blobly_run", "__slots__",
                    "pytest_configure", "tmp_path"]
            write(d, {"conftest.py": CONFTEST, "pytest.ini": "[pytest]\nblobly_project = names.blobnet\n",
                      "names.blobnet": "project:\n  name: names\n  version: 8\nchannels:\n" + "".join(
                          f"  - name: {n}\n    type: can\n    interface: inproc:PY_NAMES_{i}\n"
                          for i, n in enumerate(rows)),
                      "test_names.py": "def test_names(can_1, _2nd_bus, __slots__, pytest_configure, tmp_path, project):\n"
                                       "    assert tmp_path.is_dir(), 'a channel took pytest\\'s tmp_path'\n"
                                       "    assert (can_1.name, _2nd_bus.name) == ('CAN-1', '2nd bus')\n"
                                       "    assert (__slots__.name, pytest_configure.name) == ('__slots__', "
                                       "'pytest_configure')\n"})
            r = pytest_run(d)
            out = r.stdout + r.stderr
            self.assertEqual(r.returncode, 0, out)
            # one warning names every channel that got no fixture, and why
            self.assertIn("blobly: no fixture for 'Body Bus', 'body-bus' (as 'body_bus'); 'class' (as "
                          "'class'); 'project' (as 'project'); '_blobly_run' (as '_blobly_run'); 'tmp_path' (as "
                          "'tmp_path')", out)

    def test_a_run_from_the_repository_root_leaves_the_examples_suite_out(self):
        # its conftest's pytest_plugins is refused below a run's root, so python/conftest.py
        # leaves python/examples to its own runs (test_examples.py)
        r = pytest_run("--collect-only", "-q", REPO)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("test_pytest_plugin.py::TestPlugin", r.stdout)
        self.assertNotIn("test_sim_demo.py", r.stdout)


if __name__ == "__main__":
    unittest.main()
