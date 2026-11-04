"""The CAN bridge into WSL from Python (blobly.bridge). WSL is not on any CI runner, so what runs
here is what holds without it: on Linux no distributions and a start refused by name; everywhere a
distribution that does not exist refused by name, a bridge that is not connected idle with no rows
and refused a stop; and in an installed Windows wheel, the canbridge it carries beside its library
being the one a start runs. Starting a real bridge is checked by hand (docs/wsl_bridge.md). And the
listener a bridge on the LAN dials (BLOBLY_BRIDGE_LISTEN), started as the library loads, in a child
process since it is process-wide."""
import os
import socket
import sys

import pytest

import blobly
from blobly import _lib, bridge
from conftest import INSTALLED, REPO, run_python

pytestmark = pytest.mark.usefixtures("engine")

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


@pytest.mark.parametrize("bad", ["", None, 3])
def test_a_distribution_is_a_name(bad):
    with pytest.raises(TypeError):
        bridge.state(bad)


@pytest.mark.parametrize("call", [bridge.start, bridge.state, bridge.rows, bridge.stop])
def test_a_name_with_a_nul_is_refused_before_it_reaches_another_bridge(call):
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


@pytest.mark.skipif(not (sys.platform == "win32" and INSTALLED), reason="an installed Windows wheel carries canbridge")
def test_the_wheel_carries_the_canbridge_a_start_runs():
    prog = bridge.program()
    assert prog is not None
    assert os.path.samefile(prog, os.path.join(os.path.dirname(_lib.loaded_path), "canbridge"))
    with open(prog, "rb") as f:
        assert f.read(4) == b"\x7fELF", "canbridge is a Linux program"


LOADS = """
import socket, sys
if sys.argv[1]:
    sys.path.insert(0, sys.argv[1])
import blobly
try:
    blobly.init()
except blobly.BloblyError as e:
    print("refused:", e)
    sys.exit(0)
with socket.create_connection(("127.0.0.1", int(sys.argv[2])), timeout=5):
    print("listening")
"""


def loads_with(listen, token, port=0):
    pkg = "" if INSTALLED else os.path.join(REPO, "python")
    env = {"BLOBLY_BRIDGE_LISTEN": listen, "BLOBLY_BRIDGE_TOKEN": token}
    out = run_python("-c", LOADS, pkg, str(port), env=env, timeout=60)
    assert out.returncode == 0, out.stdout + out.stderr
    return out.stdout


def test_a_lan_listener_setting_that_cannot_be_used_is_refused_as_the_engine_loads():
    out = loads_with("board:29500", "")
    assert out.startswith("refused:") and "numeric IPv4 address" in out
    out = loads_with("0.0.0.0:29500", "short")
    assert out.startswith("refused:") and "at least 16 characters" in out


def test_a_lan_listener_is_listening_once_the_engine_has_loaded():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    assert loads_with(f"0.0.0.0:{port}", "0123456789abcdef", port) == "listening\n"
