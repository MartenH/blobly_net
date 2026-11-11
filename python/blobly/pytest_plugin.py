"""pytest_plugin — Blobly Net in a pytest suite: the suite's project, started for each test module
(or once for the session) and stopped after its last test, and a fixture for each of its channels.
A suite asks for it explicitly, in its root conftest.py:

    pytest_plugins = ["blobly.pytest_plugin"]

or with `pytest -p blobly.pytest_plugin`, or `addopts = -p blobly.pytest_plugin` in its ini file.
pytest is not a dependency of blobly, and an installed blobly adds nothing to a suite that has
not asked for it.

The project is the ini value `blobly_project` (relative to the ini file), or the command line's
`--blobly-project=PATH` (relative to the working directory), which overrides it. Write that with
`=`: pytest reads a separate PATH as a test path before a conftest's plugin has added the option.
A row is attached elsewhere than the project file says by the ini value `blobly_interfaces`, one
NAME=IFACE a line, or `--blobly-interface=NAME=IFACE` (repeatable), which replaces the ini's for
that name: blobly.Project's `interfaces`.

The ini value `blobly_run` is how long a run lasts: `module` (the default), or `session` for one
run the whole session long; `--blobly-run=session` (or `=module`) overrides it. The ini value
`blobly_channels` is what a row that does not open at a test's start costs: `lazy` (the default)
warns once per row and run, and the test that uses the row meets the error; `required` makes it
an error in every test's setup.

Fixtures:
  project    the started blobly.Project. Its run is the module's: started at the module's first
             use, stopped after its last test, so one module's simulation state never reaches the
             next (with blobly_run = session, the session's). Each test starts with what the CAN
             channels' handles hold queued read away, a handle not open opened, so it hears what
             arrives from then on and nothing an earlier test left queued, while the wire stays
             held; after it, the handlers it registered are dropped, so no later run() calls them,
             and the faults it armed are cleared.
  can1, ...  one per enabled channel, named after it: lowercased, every character that cannot be
             in a Python name made "_", and "_" put before a leading digit ("CAN-1" is can_1). A
             name two channels come to, a Python keyword, or another fixture's (this plugin's,
             pytest's own such as tmp_path, another plugin's) gets no fixture, and pytest warns
             which as it starts; reach such a channel as project.channels[...]. The names are read
             from the project (loaded, not started) as pytest configures.
  diag       a blobly.UdsClient, closed after the test: on the first enabled CAN channel at the
             default ids (0x7E0 out, 0x7E8 back), else the first DoIP one, or on the channel a test
             names by parametrizing it — @pytest.mark.parametrize("diag", ["DoIP1"],
             indirect=True), which with ["CAN1", "DoIP1"] runs the test over both. A name no
             channel has is a node of the run's system model, and the fixture a blobly.NodeClient
             on it (["zone_a"]: its DIDs read and written by name). Other ids are canN.uds(tx, rx).

A failed expect or expect_signal is a test failure whose message says what was expected and what
came instead. pytest's own --junitxml report carries it."""
import collections
import keyword
import os
import re
import warnings
from collections.abc import Iterator

import pytest

from . import __version__, init, version
from ._lib import BloblyError
from .events import monotonic_ms
from .j1939 import _discard as _discard_j1939
from .project import Channel, Project
from .uds import UdsClient

RESERVED = {"project", "diag", "request", "_blobly_run"}  # this plugin's fixtures, and pytest's request
_PATH = pytest.StashKey[str]()  # the project configure found
_NAMES = pytest.StashKey[list]()  # its enabled channels' names
RUNS = ("module", "session")  # blobly_run's values, the default first
CHANNELS = ("lazy", "required")  # blobly_channels' values, the default first
DRAIN_MS = 200  # how long a test's setup reads a channel's queue away at most
_IFACES = pytest.StashKey[dict]()  # the rows' interface overrides


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption("--blobly-project", metavar="PATH", default=None,
                     help="the .blobnet project the blobly fixtures start, relative to the working "
                          "directory (overrides the blobly_project ini value)")
    parser.addini("blobly_project", "the .blobnet project the blobly fixtures start, relative to the ini file")
    parser.addoption("--blobly-run", metavar="SCOPE", default=None,
                     help="how long a run of the project lasts: module or session (overrides the "
                          "blobly_run ini value)")
    parser.addini("blobly_run", "how long a run of the project lasts: module (the default) or session")
    parser.addini("blobly_channels", "a row that does not open at a test's start: lazy (the default, "
                                     "warned once per run) or required (the test's setup errors)")
    parser.addoption("--blobly-interface", metavar="NAME=IFACE", action="append", default=[],
                     help="attach the project's row NAME to the interface IFACE (repeatable; overrides "
                          "the blobly_interfaces ini value for that row)")
    parser.addini("blobly_interfaces", "rows attached elsewhere than the project says: one NAME=IFACE a line",
                  type="linelist")


def interface_overrides(config: pytest.Config) -> dict[str, str]:
    """The rows' interface overrides: the ini's, then --blobly-interface's over them by name. A
    pair is split at its first "=" only to lay one over the other; the engine reads the rest. A
    pair without one, or a name given twice in one place, is refused here, since a mapping cannot
    carry either to the engine."""
    out: dict[str, str] = {}
    for source, pairs in (("blobly_interfaces in the ini file", config.getini("blobly_interfaces")),
                          ("--blobly-interface", config.getoption("blobly_interface"))):
        given: dict[str, str] = {}
        for pair in pairs:
            name, eq, iface = pair.partition("=")
            if not eq:
                raise pytest.UsageError(f"{pair!r} (from {source}) is not NAME=IFACE")
            if name.strip() in given:
                raise pytest.UsageError(f"row {name.strip()!r} is given twice (from {source})")
            given[name.strip()] = iface.strip()
        out.update(given)
    return out


def project_path(config: pytest.Config) -> str | None:
    """The project the suite tests, as an absolute path: --blobly-project, else the ini value;
    None when neither names one. A path that is no file is refused."""
    given = config.getoption("blobly_project")
    if given is not None:  # given empty, it names no file: refused below, never the ini's
        path, source = os.path.join(str(config.invocation_params.dir), given), "--blobly-project"
    elif config.getini("blobly_project"):
        base = config.inipath.parent if config.inipath else config.rootpath
        path, source = os.path.join(str(base), config.getini("blobly_project")), "blobly_project in the ini file"
    else:
        return None
    path = os.path.normpath(path)
    if not os.path.isfile(path):
        raise pytest.UsageError(f"no Blobly Net project at {path} (from {source})")
    return path


def _choice(config: pytest.Config, ini: str, option: str | None, values: tuple[str, ...]) -> str:
    """A setting that is one of `values`: the command line's `option` when given, else the ini
    value, else the first of them. Anything else is refused."""
    given = config.getoption(option) if option else None
    if option and given is not None:
        value, source = given, "--" + option.replace("_", "-")
    else:
        value, source = config.getini(ini) or values[0], f"{ini} in the ini file"
    if value not in values:
        raise pytest.UsageError(f"blobly: {source} is {value!r}; it is {' or '.join(values)}")
    return value


def run_scope(config: pytest.Config) -> str:
    """How long a run of the suite's project lasts, the run fixture's scope: "module" (the
    default) or "session"; --blobly-run, else the ini value blobly_run."""
    return _choice(config, "blobly_run", "blobly_run", RUNS)


def channels_rule(config: pytest.Config) -> str:
    """What a row that does not open at a test's start costs: "lazy" (the default) or "required";
    the ini value blobly_channels."""
    return _choice(config, "blobly_channels", None, CHANNELS)


def fixture_name(channel: str) -> str:
    """The fixture a channel of this name gets: "CAN-1" is can_1, "2nd bus" is _2nd_bus."""
    name = re.sub(r"\W", "_", channel.lower(), flags=re.ASCII)
    return "_" + name if name[:1].isdigit() else name


def pytest_configure(config: pytest.Config) -> None:
    if config.getoption("help"):
        return
    path = project_path(config)
    if path is None:
        raise pytest.UsageError("no Blobly Net project: give --blobly-project=PATH, or set blobly_project "
                                "in the ini file")
    config.stash[_PATH] = path
    run_scope(config)  # refused here rather than at the first test
    channels_rule(config)
    config.stash[_IFACES] = interfaces = interface_overrides(config)
    try:
        init()  # pytest configures on the main thread, where bb.h requires the library be loaded
        # loading transmits nothing
        config.stash[_NAMES] = [ch.name for ch in Project(path, interfaces).load().channels]
    except (BloblyError, OSError) as e:  # OSError: a library that is there and will not load
        raise pytest.UsageError(f"{path}: {e}") from None


@pytest.hookimpl(trylast=True)  # after pytest's own, which sets up its fixtures
def pytest_sessionstart(session: pytest.Session) -> None:
    """A fixture per channel, registered once pytest knows its other fixtures (its own, other
    plugins'), so a channel named like one of them leaves it alone."""
    config = session.config
    names = config.stash.get(_NAMES, None)
    if names is None:
        return
    taken = RESERVED | set(getattr(getattr(session, "_fixturemanager", None), "_arg2fixturedefs", {}))
    rows = collections.defaultdict(list)
    for i, name in enumerate(names):
        rows[fixture_name(name)].append(i)
    fixtures, skipped = {}, []
    for fname, at in rows.items():
        if len(at) > 1 or not fname.isidentifier() or keyword.iskeyword(fname) or fname in taken:
            skipped.append(f"{', '.join(repr(names[i]) for i in at)} (as {fname!r})")
        else:
            # the attribute is the plugin's, the fixture's name the channel's: a channel named like
            # a hook or a dunder is still only a fixture
            fixtures[f"_blobly_channel_{at[0]}"] = _channel_fixture(fname, names[at[0]])
    if skipped:
        config.issue_config_time_warning(pytest.PytestConfigWarning(
            "blobly: no fixture for " + "; ".join(skipped) + ", a name another channel, a Python "
            "keyword or another fixture has; reach it as project.channels[...]"), stacklevel=2)
    config.pluginmanager.register(type("BloblyChannels", (), fixtures), "blobly-channels")


def _channel_fixture(fname: str, channel_name: str):
    @pytest.fixture(name=fname)
    def channel(project: Project) -> Channel:
        return project.channels[channel_name]  # by name: a reload may have moved its row
    return channel


def pytest_report_header(config: pytest.Config) -> str:
    moved = "".join(f", {name} on {iface}" for name, iface in config.stash[_IFACES].items())
    return f"blobly {__version__}, engine {version()}, project {config.stash[_PATH]}{moved}"


class _Run:
    """A run of the suite's project as the fixtures hold it: the project, and the rows whose
    failure to open has been warned of in it."""

    def __init__(self, net: Project) -> None:
        self.net = net
        self.said: set[str] = set()


def _run_scope(fixture_name: str, config: pytest.Config) -> str:
    return run_scope(config)


@pytest.fixture(scope=_run_scope)
def _blobly_run(request: pytest.FixtureRequest) -> Iterator[_Run]:
    """The module's run of the suite's project, or the session's (blobly_run)."""
    with Project(request.config.stash[_PATH], request.config.stash[_IFACES]) as net:
        yield _Run(net)


@pytest.fixture
def project(_blobly_run: _Run, request: pytest.FixtureRequest) -> Iterator[Project]:
    """The started project; what a test registers on it and leaves queued goes with the test."""
    net = _blobly_run.net
    if not net.started:  # an earlier test of the run stopped it
        net.start()
    _say_unopened(request.config, _blobly_run, _reopen(net))
    yield net
    net._forget()
    if net.started:
        net._stop_senders()
        net.clear_faults()
        net.clear_signals()


@pytest.fixture
def diag(project: Project, request: pytest.FixtureRequest) -> Iterator[UdsClient]:
    """A UDS client, closed after the test: on the channel the test names by parametrizing this
    fixture indirectly — or, for a name no channel has, a NodeClient on that node of the run's
    system model — else on the project's first enabled CAN channel at the default ids (0x7E0 out,
    0x7E8 back), else its first DoIP one; other ids are canN.uds(tx, rx)."""
    name = getattr(request, "param", None)
    if name is not None:
        if not isinstance(name, str) or (name not in project.channels.keys() and name not in project.nodes.keys()):
            pytest.fail(f"diag: parametrized with {name!r}, which is no enabled channel's name nor a node's; "
                        f"the channels are: {', '.join(project.channels.keys())}; the nodes: "
                        f"{', '.join(project.nodes.keys()) or 'none (no system.toml)'}", pytrace=False)
        if name not in project.channels.keys():
            with project.nodes[name].uds() as node:
                yield node
            return
        ch = project.channels[name]
    else:
        rows = [(c, c.kind) for c in project.channels]
        ch = next((c for c, kind in rows if kind == "can"), None) or next((c for c, kind in rows if kind == "doip"), None)
        if ch is None:
            pytest.fail("diag: the project has no enabled CAN or DoIP channel", pytrace=False)
    with ch.uds() as client:
        yield client


def _say_unopened(config: pytest.Config, run: _Run, unopened: list[tuple[str, str, str]]) -> None:
    """The rows that did not open said: under blobly_channels = required the test's setup fails on
    one line naming every one; otherwise a PytestWarning per row, once in the run."""
    said = [f"{name} ({iface}) did not open: {why}" for name, iface, why in unopened]
    if not said:
        return
    if channels_rule(config) == "required":
        pytest.fail("blobly: " + "; ".join(said), pytrace=False)
    for (name, _, _), text in zip(unopened, said):
        if name not in run.said:
            run.said.add(name)
            warnings.warn(pytest.PytestWarning("blobly: " + text), stacklevel=2)


def _reopen(net: Project) -> list[tuple[str, str, str]]:
    """Each CAN channel's handle read until nothing is queued (opened first where it is not open),
    so what arrives before the test's first use of it is kept for it, and nothing from before,
    without letting go of the wire: the read is also what makes a handle on a shared wire (PCAN,
    CANsub, the CAN bridge) a subscriber, where an unread one keeps only its first second. The
    row's UDS clients and ISO-TP channels are let go. Each LIN bus is tapped afresh, which holds
    no device; a value an earlier test set with `set()` stays, since it is what the simulated
    node publishes. Returns (name, interface, error) for each row that did not open."""
    unopened = []
    for b in net.lin if net.started else []:
        try:
            b.close()  # a project's bus is untapped, and tapped again at once
            b._handle()
        except BloblyError as e:
            unopened.append((b.name, b.address, str(e)))
    for ch in net.channels:
        ch._let_go_clients()
        if ch.kind == "can":
            try:
                _drain(ch)
            except BloblyError:
                try:  # a handle that will not read is replaced
                    ch.close()
                except BloblyError:
                    pass  # a handle already gone is closed enough
                try:
                    _drain(ch)
                except BloblyError as e:
                    unopened.append((ch.name, ch.iface, str(e)))
    return unopened


def _drain(ch: Channel) -> None:
    """What the channel's handle holds queued read away, the handle opened where it is not: until
    a look finds nothing, or DRAIN_MS at most, so a busy bus cannot hold a test's setup; and the
    J1939 messages and faults those frames completed let go, and the E2E counter check begun again
    at the next frame, so what an earlier test did to a sender (a drop fault since cleared) is not
    judged in this one; and the newest frame per id forgotten, so `latest` and `value` answer from
    what this test reads, as on a handle just opened."""
    end = monotonic_ms() + DRAIN_MS
    while True:
        f, spent = ch.look()
        if (f is None and not spent) or monotonic_ms() >= end:
            break
    ch._latest = {}
    _discard_j1939(ch, ch._handle())
    ch._judge_afresh()
