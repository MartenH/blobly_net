"""A pytest suite against sim-demo's simulated ECUs: a module-scoped fixture starts the project
once, and the tests talk to it.

    pip install pytest
    pytest python/examples/test_sim_demo.py

BLOBLY_PROJECT=<path> runs it against another project; the tests expect sim-demo's channels and
database. pytest is not a dependency of blobly: install it yourself.

Two things to know when you write your own:
  - One run per process. The `net` fixture holds the run for the whole module and stops it after
    the module's last test, so the next module's fixture can start its own.
  - Handlers last as long as their Project: there is no call to remove one. A test that registers
    on_message or on_timer handlers and calls run() leaves them registered, and a later test's
    run() calls them too. Keep such a test last in its module, as here, or give it a module of
    its own."""
import os
import sys
import time
from collections.abc import Iterator
from importlib.util import find_spec

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
if find_spec("blobly") is None:  # not installed: use this checkout's python/blobly
    sys.path.insert(0, os.path.join(HERE, os.pardir))
import blobly  # noqa: E402

PROJECT = os.environ.get("BLOBLY_PROJECT") or os.path.join(HERE, os.pardir, os.pardir, "projects",
                                                           "sim-demo.blobnet")


@pytest.fixture(scope="module")
def net() -> Iterator[blobly.Project]:
    """The project, started for this module and stopped after its last test."""
    blobly.init()  # pytest runs tests on the main thread, where the library must be loaded
    print(f"blobly {blobly.__version__}, engine {blobly.version()}")  # shown with pytest -s
    with blobly.Project(PROJECT) as project:
        yield project


@pytest.fixture
def can1(net: blobly.Project) -> blobly.Channel:
    return net.channels.CAN1


def drain(ch: blobly.Channel, limit_ms: float = 200) -> None:
    """Drops what is queued on the channel now (frames sent before this test began), for at most
    limit_ms: a look that stopped at its bound with records still queued (`spent`) looks again."""
    deadline = time.monotonic() + limit_ms / 1000
    while time.monotonic() < deadline:
        frame, spent = ch.look()
        if frame is None and not spent:
            return


def wait_for(ch: blobly.Channel, frame_id: int, timeout_ms: float, ext: bool = False) -> blobly.Frame | None:
    """The first frame with this id and kind within timeout_ms, else None; others are consumed."""
    deadline = time.monotonic() + timeout_ms / 1000
    while (left_ms := (deadline - time.monotonic()) * 1000) > 0:
        f = ch.recv(left_ms)
        if f is not None and f.id == frame_id and f.ext == ext:
            return f
    return None


def test_the_project_has_its_channels(net: blobly.Project) -> None:
    kinds = {ch.name: ch.kind for ch in net.channels}
    assert kinds == {"CAN1": "can", "CAN2": "can", "DoIP1": "doip"}


def test_the_sut_answers_a_raw_request(can1: blobly.Channel) -> None:
    drain(can1)
    can1.send(0x101, b"\x05")
    answer = wait_for(can1, 0x102, 1000)
    assert answer is not None, "no 0x102 within 1000 ms"
    assert answer.data[0] == 0x06


def test_powertrain_stays_in_its_dbc_range(can1: blobly.Channel) -> None:
    powertrain = can1.messages.Powertrain
    frame = wait_for(can1, powertrain.id, 1000)  # sent every 100 ms
    assert frame is not None, "no Powertrain within 1000 ms"
    for name, value in can1.decode(frame).items():
        sig = powertrain.signals[name]
        assert sig.minimum <= value <= sig.maximum, f"{name}={value} {sig.unit}"


@pytest.mark.parametrize("rpm", [0, 1500, 16383.75])
def test_engine_speed_encodes_and_decodes(can1: blobly.Channel, rpm: float) -> None:
    frame = can1.messages.Powertrain.encode(EngineSpeed=rpm, Gear=4)
    values = can1.decode(frame)
    assert (values["EngineSpeed"], values["Gear"]) == (rpm, 4)


def test_requests_are_answered_during_run(net: blobly.Project, can1: blobly.Channel) -> None:
    # last in the module: its handlers stay registered after it
    msgs = can1.messages
    sent: list[int] = []
    answers: list[int] = []

    def send() -> None:
        sent.append(len(sent) + 1)
        msgs.Request.send(ReqCode=sent[-1])

    net.on_message(can1, msgs.Response, lambda f: answers.append(int(can1.decode(f)["RespCode"])))
    net.on_timer(50, send)
    net.run(500)
    assert len(answers) >= 3, f"{len(answers)} answer(s) to {len(sent)} request(s)"
    assert all(a - 1 in sent for a in answers), (answers, sent)
