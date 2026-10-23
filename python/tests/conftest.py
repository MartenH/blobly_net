"""What python/tests share: the repository's paths, the package under test, the engine fixture, a
started sim-demo, a scratch file writer and a child Python run as this one is.

The package is the source tree's (python/blobly, put first on sys.path here, before any test module
imports it), unless the run is of an installed wheel (BLOBLY_TEST_INSTALLED). Then nothing of the
source tree is on sys.path in a run of python/tests: pytest.ini makes this folder the run's root, so
python/conftest.py (loaded by a run from above, which would put python/ on sys.path) is not, and
test_project.py's TestInstalledWheel asserts that the wheel's copy was loaded."""
import os
import subprocess
import sys
import tempfile

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
SIM_DEMO = os.path.join(REPO, "projects", "sim-demo.blobnet")
DEMO = os.path.join(REPO, "projects", "demo.blobnet")  # its CAN1 is vcan0, sim-demo's inproc:CAN1
INSTALLED = bool(os.environ.get("BLOBLY_TEST_INSTALLED"))

if not INSTALLED:
    sys.path.insert(0, os.path.join(REPO, "python"))
import blobly  # noqa: E402
from blobly import _lib  # noqa: E402


@pytest.fixture(scope="session")
def engine():
    """The library loaded; a module using it is skipped where none is found, unless the run was
    told where one is (BLOBLY_LIB, or an installed wheel), so a missing build fails in CI."""
    try:
        _lib.lib()
    except blobly.BloblyError as e:
        if os.environ.get("BLOBLY_LIB") or INSTALLED:
            raise
        pytest.skip(str(e))


@pytest.fixture(scope="class")
def sim_demo(engine):
    """projects/sim-demo.blobnet started for a class's tests and stopped after them (outside a class,
    for the one test): one run per process, so a test that brings up its own project runs in
    another class."""
    net = blobly.Project(SIM_DEMO).start()
    yield net
    net.stop()


def write(d, name, text):
    """`text` written to d/name; its path, as a string."""
    path = os.path.join(d, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return path


def run_python(*args, env=None, timeout=120):
    """`python <args>` as its own process, isolated as this one is, from a scratch directory."""
    env = dict(os.environ, **(env or {}))
    if env.get("BLOBLY_LIB"):
        env["BLOBLY_LIB"] = os.path.abspath(env["BLOBLY_LIB"])  # the child's directory is not ours
    flags = ["-B"] + (["-I"] if sys.flags.isolated else [])
    with tempfile.TemporaryDirectory() as cwd:
        return subprocess.run([sys.executable, *flags, *args], cwd=cwd, env=env, capture_output=True,
                              text=True, encoding="utf-8", errors="replace", timeout=timeout)
