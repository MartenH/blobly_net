# Using Blobly Net from VS Code

VS Code with its Python extension is where you write, run, debug and poke at Blobly Net from
Python. The GUI has no Python inside it and no console panel. Instead, VS Code gives you:

- completion and hover help while you write, from the `blobly` package's type annotations;
- breakpoints in scripts and in pytest tests;
- the Debug Console at a breakpoint, an interactive console against the live project;
- the Testing panel, which runs a pytest suite through `blobly.pytest_plugin`;
- `# %%` cells, run one at a time against a project that stays up between them.

The package itself is described in [scripting_python.md](scripting_python.md).

## Setting up

Install VS Code's **Python** extension (`ms-python.python`). It brings Pylance, which does the
completion and hover, and the Python Debugger. For `# %%` cells you also need the **Jupyter**
extension (`ms-toolsai.jupyter`).

Make a virtual environment in the folder you open, and install the package and pytest into it:

```sh
python3 -m venv .venv
. .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install blobly pytest
```

Then run **Python: Select Interpreter** from the Command Palette and choose `.venv`. VS Code
usually offers it on its own when the folder has one. The terminals VS Code opens activate it.

[python/examples](../python/examples/README.md) carries a ready
[`.vscode/`](../python/examples/.vscode) folder. Open `python/examples` itself as the folder
(**File ▸ Open Folder…**), or copy it, `.vscode/` included, to start a project of your own.
VS Code reads a `.vscode/` folder only at the root of the folder it opened, so these files do
nothing when you open the whole repository.

- [`settings.json`](../python/examples/.vscode/settings.json) turns on pytest discovery in the
  folder.
- [`launch.json`](../python/examples/.vscode/launch.json) runs and debugs the current file, the
  current file with arguments you type, or the tests of the current file whose name you have
  selected.

The examples find `projects/sim-demo.blobnet` relative to themselves. In a copy outside the
repository, give the project as an argument (**Example: current file, with arguments**), and
point `blobly_project` in the copy's `pytest.ini` at your project.

## Running an example

Open [raw_can.py](../python/examples/raw_can.py) and press **F5** with
**Example: current file** selected in the Run and Debug view. The engine's own lines
(`project: ...`, `channel CAN1 ...`) and the example's output appear in the terminal. Set a
breakpoint by clicking left of a line number first, and the run stops there.

**Stop** (Shift+F5) ends the process at once. A `with` block's `stop()` does not run: the run
belongs to the process, and its buses and sockets close with it.

## The Testing panel

With `settings.json` in place, the Testing panel (the flask icon) lists the tests of
[test_sim_demo.py](../python/examples/test_sim_demo.py). Run all of them, one file, or one test
from the panel or from the icon beside each `def test_`. A failed `expect` shows its message,
which says what was expected and what came instead.

The suite asks for the plugin in [conftest.py](../python/examples/conftest.py) and names its
project in [pytest.ini](../python/examples/pytest.ini), as any suite does
([Testing with pytest](scripting_python.md#15-testing-with-pytest)). To test another project,
add `"--blobly-project=path/to/your.blobnet"` to `python.testing.pytestArgs` in
`settings.json`. Keep the `=`.

## Debugging a test

Set a breakpoint inside a test and choose **Debug Test** from the panel, or from the menu of the
icon beside it. The test stops with its fixtures in the frame: `can1`, `diag` and `project` are
variables you can look at in the Variables view, and use in the Debug Console.

**pytest: the selected test, or the file** in `launch.json` does the same from the editor:
double-click a test's name to select it, then press F5. It runs the file's tests whose names
contain the selection (pytest's `-k`), or all of them when nothing is selected.

## The Debug Console

When a script or a test stops at a breakpoint, the Debug Console (**View ▸ Debug Console**)
runs Python in the paused frame. The project is up and its simulated ECUs are running, so the
console is a live tester. Completion there asks the live objects, so the project's own names
complete: `can1.messages.` lists `BatteryStatus`, `BodyStatus`, `BrakeStatus`, and the rest.

Stopped at the first line of `test_a_fired_generator_is_answered`, whose frame holds `project`
and `can1`:

```text
> can1.messages.Request.encode(ReqCode=5)
Frame(0x101 [05 00 00 00 00 00 00 00])
> can1.decode(can1.messages.Request.encode(ReqCode=5))
{'ReqCode': 5.0}
> can1.send(0x101, b"\x05")
> can1.expect(0x102, timeout_ms=500)
Frame(0x102 [06])
> diag = can1.uds()
> diag.read_did(0xF190)
b'BLOBLYNETV0SUT001'
> [d.name for d in diag.dtcs()]
['P1234-56', 'B2BCD-EF']
> ping = project.generators["Ping ECU (Request)"]
> ping.fire()
> can1.expect(can1.messages.Response, timeout_ms=500)
Frame(0x102 [02 00 00 00 00 00 00 00])
> can1.diagnostics()
BusDiagnostics(dropped=0, bus_errors=0, decode_errors=0)
```

**The simulation does not pause with you.** The debugger stops your Python code, but the
engine's threads are not Python's. While you are stopped, the simulated ECUs go on sending and
frames queue on the channel.

- **A frame you read in the console is consumed.** If you read the answer a test is about to
  `expect`, the test does not get it, and fails.
- **The queue fills.** On sim-demo's CAN1 it is full after about a minute and a half, and frames
  that arrive after that are dropped (`can1.diagnostics().dropped` counts them). An `expect`
  after a send then reads thousands of old frames and times out. Call `can1.close()` first: the
  next use opens a fresh handle, which hears only what arrives from then on.
- **An ECU's state moves on.** A real ECU leaves a non-default session after its S3 time
  (typically 5 s) without a request, so ask for the session again after a long pause. A DoIP
  connection the entity has closed raises `ConnectionLost`, and the next call opens another.

## Cells

With the Jupyter extension, a `.py` file split by `# %%` lines shows **Run Cell** above each
cell. The cells run in the Interactive Window, in one Python kernel that stays up between them.
VS Code asks to install `ipykernel` into the environment the first time.

```python
# %%
import blobly

net = blobly.Project("projects/sim-demo.blobnet").start()
can1 = net.channels.CAN1

# %%
can1.send(0x101, b"\x05")
can1.expect(0x102, timeout_ms=500)

# %%
net.stop()
```

- **Use `start()` and `stop()`, not `with`.** A `with` block ends with its cell.
- **One run per kernel**, as per process: running the first cell again raises `BloblyError`
  with code -3. Run `net.stop()` first, or restart the kernel.
- **A relative path is relative to the file's folder**, the kernel's working directory. The
  block above is written for a file at the repository root.
- **Interrupt** (the Interactive Window's toolbar) ends a wait within 100 ms, as Ctrl-C does.

## On Windows

- Make the environment with the Python launcher: `py -3.12 -m venv .venv`, then
  `.venv\Scripts\activate` and `pip install blobly pytest`. The interpreter to select is
  `.venv\Scripts\python.exe`. If PowerShell refuses to run the activation script,
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` allows it.
- The vendor DLLs (`PCANBasic.dll`, `canlib32.dll`, `vxlapi64.dll`) come from the vendors'
  drivers, not from the wheel, and load when a channel first opens, under the debugger as
  anywhere else. Vector's `vxlapi64.dll` is a separate download. See
  [Adapters](scripting_python.md#adapters).
- VS Code on Windows runs the Windows wheel, which reaches WSL's CAN interfaces through the
  bridge ([The WSL bridge](scripting_python.md#the-wsl-bridge)). A window opened inside WSL
  (the WSL extension) runs the Linux wheel, with `vcan0` directly.

## What completion knows

**In the editor**, completion and hover come from the package's annotations (it ships
`py.typed`). They cover every method, its parameters and its docstring, and the type each call
returns. `net.channels.CAN1` is a `Channel` and `can1.messages.Request` a `Message`, so
`.send(`, `.expect(` and `.encode(` complete after them.

**The names are another matter.** `CAN1`, `Request` and `ReqCode` come from the project file
and its databases, which are read at run time. The editor does not offer them, does not flag a
misspelt one, and does not check the signal names you pass to `encode` or `send`.

**In the Debug Console and the Interactive Window**, the names complete, because completion
there asks the running objects. That is the place to explore a project.

**A test's fixtures** are made by the plugin at run time, so annotate them for completion:

```python
from blobly import Channel, UdsClient


def test_the_vin(can1: Channel, diag: UdsClient):
    assert diag.read_did(0xF190) == b"BLOBLYNETV0SUT001"
```

A generator of stubs that would give the editor a project's channel, message and signal names
may come later ([#507](https://github.com/MartenH/blobly_net/issues/507)).
