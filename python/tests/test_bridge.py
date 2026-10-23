"""The CAN bridge into WSL from Python (blobly.bridge). WSL is not on any CI runner, so what runs
here is what holds without it: on Linux no distributions and a start refused by name; everywhere a
distribution that does not exist refused by name, a bridge that is not connected idle with no rows
and refused a stop; and in an installed Windows wheel, the canbridge it carries beside its library
being the one a start runs. Starting a real bridge is checked by hand (docs/wsl_bridge.md)."""
import os
import sys
import unittest

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if not os.environ.get("BLOBLY_TEST_INSTALLED"):
    sys.path.insert(0, os.path.join(HERE, ".."))
import blobly  # noqa: E402
from blobly import _lib, bridge  # noqa: E402

NOBODY = "blobly-no-such-distribution"


def test_a_distribution_that_is_not_installed_is_refused_by_name():
    with pytest.raises(blobly.Refused) as e:
        bridge.start(NOBODY)
    assert (NOBODY if sys.platform == "win32" else "the Windows build") in str(e.value)


def test_a_bridge_that_is_not_connected_is_idle_without_rows_and_cannot_be_stopped():
    assert bridge.state(NOBODY) == ("idle", "")
    assert bridge.rows(NOBODY) == []
    with pytest.raises(blobly.BloblyError) as e:
        bridge.stop(NOBODY)
    assert e.value.code == _lib.BB_ERR_STATE
    assert f'no bridge named "{NOBODY}" is connected' in str(e.value)


def test_a_distribution_is_a_name():
    for bad in ("", None, 3):
        with pytest.raises(TypeError):
            bridge.state(bad)
    for call in (bridge.start, bridge.state, bridge.rows, bridge.stop):
        with pytest.raises(ValueError, match="NUL"):
            call("Ubuntu\0other")


def test_the_distributions_are_names():
    names = bridge.distributions()
    assert names == sorted(names) and all(isinstance(n, str) and n for n in names)


@pytest.mark.skipif(sys.platform == "win32", reason="the bridge is started from Windows")
def test_on_linux_there_is_nothing_to_start_a_bridge_in():
    assert bridge.distributions() == []
    assert bridge.program() is None
    with pytest.raises(blobly.Refused, match="the Windows build"):
        bridge.start("Ubuntu-24.04")


@pytest.mark.skipif(not (sys.platform == "win32" and os.environ.get("BLOBLY_TEST_INSTALLED")),
                    reason="an installed Windows wheel carries canbridge")
def test_the_wheel_carries_the_canbridge_a_start_runs():
    prog = bridge.program()  # loads the library, so loaded_path is set
    assert prog is not None
    assert os.path.samefile(prog, os.path.join(os.path.dirname(_lib.loaded_path), "canbridge"))
    with open(prog, "rb") as f:
        assert f.read(4) == b"\x7fELF", "canbridge is a Linux program"


def load_tests(loader, tests, pattern):
    """These are pytest tests; under `unittest discover` each runs as a FunctionTestCase, a
    pytest skip (raised or marked) as a unittest skip."""
    suite = unittest.TestSuite()
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            suite.addTest(unittest.FunctionTestCase(_unittest_body(fn), description=name))
    return suite


def _unittest_body(fn):
    def body():
        for mark in getattr(fn, "pytestmark", []):
            if mark.name == "skipif" and mark.args and mark.args[0]:
                raise unittest.SkipTest(mark.kwargs.get("reason", ""))
        try:
            fn()
        except pytest.skip.Exception as e:
            raise unittest.SkipTest(str(e)) from e
    return body
