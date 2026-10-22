"""pytest_plugin — Blobly Net in a pytest suite: the suite's project, started for each test module
and stopped after its last test, and a fixture for each of its channels. A suite asks for it
explicitly, in its root conftest.py:

    pytest_plugins = ["blobly.pytest_plugin"]

or with `pytest -p blobly.pytest_plugin`, or `addopts = -p blobly.pytest_plugin` in its ini file.
pytest is not a dependency of blobly, and an installed blobly adds nothing to a suite that has
not asked for it.

The project is the ini value `blobly_project` (relative to the ini file), or the command line's
`--blobly-project=PATH` (relative to the working directory), which overrides it. Write that with
`=`: pytest reads a separate PATH as a test path before a conftest's plugin has added the option.

Fixtures:
  project    the started blobly.Project. Its run is the module's: started at the module's first
             use, stopped after its last test, so one module's simulation state never reaches the
             next. Each test gets the CAN channels' handles opened fresh as it starts, so it hears
             what arrives from then on and nothing an earlier test left queued; after it, the
             handlers it registered are dropped, so no later run() calls them, and the faults it
             armed are cleared.
  can1, ...  one per enabled channel, named after it: lowercased, every character that cannot be
             in a Python name made "_", and "_" put before a leading digit ("CAN-1" is can_1). A
             name two channels come to, a Python keyword, or another fixture's (this plugin's,
             pytest's own such as tmp_path, another plugin's) gets no fixture, and pytest warns
             which as it starts; reach such a channel as project.channels[...]. The names are read
             from the project (loaded, not started) as pytest configures.
  diag       a blobly.UdsClient, closed after the test: on the first enabled CAN channel at the
             default ids (0x7E0 out, 0x7E8 back), else the first DoIP one, or on the channel a test
             names by parametrizing it — @pytest.mark.parametrize("diag", ["DoIP1"],
             indirect=True), which with ["CAN1", "DoIP1"] runs the test over both. Other ids are
             canN.uds(tx, rx).

A failed expect or expect_signal is a test failure whose message says what was expected and what
came instead. pytest's own --junitxml report carries it."""
import collections
import keyword
import os
import re

import pytest

from . import __version__, init, version
from ._lib import BloblyError
from .project import Channel, Project

RESERVED = {"project", "diag", "request", "_blobly_run"}  # this plugin's fixtures, and pytest's request
_PATH = pytest.StashKey[str]()  # the project configure found
_NAMES = pytest.StashKey[list]()  # its enabled channels' names


def pytest_addoption(parser: pytest.Parser) -> None:
    parser.addoption("--blobly-project", metavar="PATH", default=None,
                     help="the .blobnet project the blobly fixtures start, relative to the working "
                          "directory (overrides the blobly_project ini value)")
    parser.addini("blobly_project", "the .blobnet project the blobly fixtures start, relative to the ini file")


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
    try:
        init()  # pytest configures on the main thread, where bb.h requires the library be loaded
        config.stash[_NAMES] = [ch.name for ch in Project(path).load().channels]  # loading transmits nothing
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
    return f"blobly {__version__}, engine {version()}, project {config.stash[_PATH]}"


@pytest.fixture(scope="module")
def _blobly_run(request: pytest.FixtureRequest):
    """The module's run of the suite's project."""
    with Project(request.config.stash[_PATH]) as net:
        yield net


@pytest.fixture
def project(_blobly_run: Project):
    """The started project; what a test registers on it and leaves queued goes with the test."""
    net = _blobly_run
    if not net.started:  # an earlier test of the module stopped it
        net.start()
    _reopen(net)
    yield net
    net._forget()
    if net.started:
        net.clear_faults()


@pytest.fixture
def diag(project: Project, request: pytest.FixtureRequest):
    """A UDS client, closed after the test: on the channel the test names by parametrizing this
    fixture indirectly, else on the project's first enabled CAN channel at the default ids (0x7E0
    out, 0x7E8 back), else its first DoIP one; other ids are canN.uds(tx, rx)."""
    name = getattr(request, "param", None)
    if name is not None:
        if not isinstance(name, str) or name not in project.channels.keys():
            pytest.fail(f"diag: parametrized with {name!r}, which is no enabled channel's name; there are: "
                        f"{', '.join(project.channels.keys())}", pytrace=False)
        ch = project.channels[name]
    else:
        rows = [(c, c.kind) for c in project.channels]
        ch = next((c for c, kind in rows if kind == "can"), None) or next((c for c, kind in rows if kind == "doip"), None)
        if ch is None:
            pytest.fail("diag: the project has no enabled CAN or DoIP channel", pytrace=False)
    with ch.uds() as client:
        yield client


def _reopen(net: Project) -> None:
    """Each CAN channel's handle opened now and read once, so what arrives before the test's
    first use of it is kept for it, and nothing from before: the read is what makes a handle on
    a shared wire (PCAN, CANsub, the CAN bridge) a subscriber, where an unread one keeps only
    its first second."""
    for ch in net.channels:
        try:
            ch.close()
        except BloblyError:
            pass  # a handle already gone is closed enough
        if ch.kind == "can":
            try:
                ch.look()
            except BloblyError:
                pass  # the test that uses the channel meets the error
