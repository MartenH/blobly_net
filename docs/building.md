# Getting and building Blobly Net

How to install a release, take a build of `main` between releases, and build from source on
Linux, Windows and macOS. **The CI workflows are the source of truth**:
[`ci.yml`](../.github/workflows/ci.yml) and [`windows.yml`](../.github/workflows/windows.yml)
build from nothing on a clean runner on every push, so if this page and they disagree, believe
them.

1. [Releases](#releases)
2. [Between releases](#between-releases)
3. [Linux and WSL2 from source](#linux-and-wsl2-from-source)
4. [Native Windows from source](#native-windows-from-source)
5. [macOS from source](#macos-from-source)
6. [Command-line tools (source checkout only)](#command-line-tools-source-checkout-only)
7. [Dependencies](#dependencies)

---

## Releases

**[Releases](../../../releases)** carry two bundles per version, a Linux **tar.gz** and a Windows
**zip**, with no GitHub sign-in and no expiry, plus the two Python wheels (Linux x86_64, Windows
x64) that `pip install blobly` takes from PyPI. Ignore the `v-toolchain` entry: that is CI's
prebuilt compiler. Releases from `v0.1.0` onward are the product.

Both bundles carry the demo projects, DBCs, sample logs, the docs the Help menu renders, the
engine as a shared library with its header (`bb.h`), a `README.txt` and a `VERSION.txt` under one
top-level folder. They do not carry the command-line tools under `cmd/` (the Lua runner, `restbus`,
`vectorcheck` and the rest), which the guides mention: those are
[built from a checkout](#command-line-tools-source-checkout-only).

- **Windows**: the zip is self-contained (MinGW runtime DLLs included). Run the bundled
  `register_blobnet_win.ps1` to make `.blobnet` files open in the app. The bundle also carries
  `canbridge` for the [WSL bridge](wsl_bridge.md).
- **Linux**: Ubuntu 24.04 or newer, or another Linux whose glibc is at least as new as 24.04's.
  Unpack the tar.gz, install the runtime it links against, then run `./blobly_net`:

  ```sh
  sudo apt install libglfw3 libfreetype6 libgl1     # GLFW is usually the only one missing
  ```

**Which version you have:** `VERSION.txt`, the window title, or `./blobly_net --version`. On
Windows the exe is a GUI-subsystem program, so pipe it: `blobly_net.exe --version | more`.

**Vendor CAN libraries are never bundled.** `vxlapi64.dll`, `PCANBasic.dll` and `canlib32.dll`
come with the vendors' own driver installs (the Vector XL terms forbid redistributing it, and
Vector's `vxlapi64.dll` is a separate download from its hardware drivers). See
[windows_can_hardware.md](windows_can_hardware.md).

Every release is cut from a tag the release workflow verifies against reviewed `main` and against
the version in `v.mod`, which is the same value the binary decodes and reports. How a release is
cut: [releasing.md](releasing.md).

## Between releases

CI builds `main` on every push. Pull requests compile-validate but publish no artifact, so every
downloadable build comes from reviewed `main`. Two caveats for both: downloading an artifact
requires being signed in to GitHub, and artifacts expire (about 90 days), so use a recent run.

**Windows.** **[Actions](../../../actions/workflows/windows.yml)** → the latest `windows-build`
run **on `main`** → the **`blobly_net-windows-x64`** artifact. Unzip and run `blobly_net.exe`:
the same self-contained contents as a release zip, minus the top-level folder.

**Linux.** **[Actions](../../../actions/workflows/ci.yml)** → the latest `ci` run **on `main`** →
the **`blobly_net-linux-x64`** artifact, built on Ubuntu 24.04 like a release, so it has the
same floor. Inside the downloaded zip is a `.tar.gz`: GitHub zips every artifact and strips the
executable bit doing it, so unpack the tar rather than the binary:

```sh
unzip blobly_net-linux-x64.zip && tar -xzf blobly_net-linux-x64.tar.gz
./blobly_net-linux-x64/blobly_net
```

It is the **executable plus the licence texts** (`licenses/`), not a bundle: no projects, DBCs,
samples or docs, and it needs the distro runtime (`sudo apt install libglfw3 libfreetype6
libgl1`). For everything in one folder, take a release.

**Python.** A wheel built from a checkout carries a local version label naming the commit
(`2026.10.1+git.8027a81`), which PyPI refuses. To use the Python package from `main`, build the
library and point Python at the checkout; see
[scripting_python.md, From a source checkout](scripting_python.md#from-a-source-checkout).

## Linux and WSL2 from source

Ubuntu 24.04 is what this is developed on. Under WSL2 the GUI renders through **WSLg**, so there
is no X server to set up, but hardware GL wants a current Mesa (25.x is known good; older Mesa
crashed the GPU path).

```sh
sudo ./scripts/setup_sudoers.sh   # optional: scoped passwordless sudo (apt-get/ip/modprobe/insmod)
./scripts/setup_env.sh            # V + native deps (GLFW/FreeType) + can-utils, builds the GUI,
                                  # brings up vcan0, runs the tests
./scripts/run_gui.sh              # build + run the GUI
```

To open a given project and start it straight away, with no hardware:

```sh
BLOBLY_PROJECT=projects/sim-demo.blobnet BLOBLY_AUTOSTART=1 scripts/run_gui.sh
```

The simulated ECUs are native (`blobly/sim`) and run in-process.

**Running the tests:**

```sh
./scripts/unit_tests.sh                     # unit tests, one job per core
./scripts/runtests.sh                       # every headless Lua suite in tests/ (CI's command)
./scripts/runtests.sh tests/diag_basic.lua  # or name them
```

Point a Lua run at another project with `--project projects/<name>.blobnet`.

**The engine as a library**, for Python or C from a checkout:

```sh
./scripts/build_libblobly.sh build          # build/libblobly.so
export PYTHONPATH=$PWD/python
```

**Real CAN under WSL2:** USB is not exposed by default, so attach the adapter with `usbipd-win`
first (`scripts/usbip.sh attach <busid>`); the kernel driver then creates `can0` as on native
Linux. The WSL kernel requirements are in [can_hardware.md](can_hardware.md).

**The V toolchain is pinned.** `.v-version` names the V commit this repository is known to pass
on, and `.vc-version` the bootstrap that builds it. `setup_env.sh` installs exactly that pair.

## Native Windows from source

Native Windows is a different toolchain: MSYS2 / MinGW (`UCRT64`), not the Linux scripts. The
recipe is [`windows.yml`](../.github/workflows/windows.yml), which CI runs on every push; unlike a
hand-written walkthrough it cannot quietly drift. Or skip building and take a
[release](#releases) or a [between-release build](#between-releases).

The packages it installs are under [Dependencies](#dependencies). The V toolchain CI uses on
Windows is the pinned V cross-built from Linux, downloaded from this repository's `v-toolchain`
release.

## macOS from source

Apple Silicon, built from source. There is no prebuilt bundle and no macOS build or test job;
CI type-checks every command-line tool for macOS, nothing more. `scripts/setup_env.sh` is
Linux-only, so the toolchain is set up by hand.

The GUI, the engine and the CAN-free transports work: `inproc:`, `udp:` (pinned to loopback on
macOS), `bridge:` and a CANsub. There is no SocketCAN and no PCAN/Kvaser/Vector driver on macOS,
so an address of theirs is refused by name.

```sh
xcode-select --install                     # clang, make, git
brew install glfw freetype pkg-config      # the GUI's native dependencies

# the V this repository pins (.v-version) and its bootstrap (.vc-version), fetched by commit:
git clone https://github.com/vlang/v ~/v && cd ~/v
git checkout --detach "$(cat /path/to/blobly_net/.v-version)"
git clone https://github.com/vlang/vc vc
git -C vc checkout --detach "$(cat /path/to/blobly_net/.vc-version)"
make local=1                               # local=1: do not pull a newer bootstrap
./v version                                # must name the commit in .v-version

cd /path/to/blobly_net
export V=~/v/v V_MACOS_V3_NO_FALLBACK=1    # the pinned V, and no silent fallback to another
scripts/run_gui.sh                         # builds libs/vgui once, then the GUI
```

- Homebrew in another place than `/opt/homebrew` or `/usr/local` (a custom `HOMEBREW_PREFIX`)
  needs its `lib` folder on the linker path: `export LIBRARY_PATH=<prefix>/lib`.
- A V that names another commit is the usual failure: it builds the dependencies and then
  crashes in the compiler. An existing V checkout without an `origin` remote is moved with
  `git fetch https://github.com/vlang/v <commit> && git checkout --detach FETCH_HEAD`.
- `v -enable-globals test blobly/` passes on macOS (checked by hand). The loopback DoIP
  announcement test skips: macOS's loopback has no broadcast, so a loopback entity's
  announcements cannot be heard ([known issues](known_issues.md)). DoIP over TCP and asking an
  entity are unaffected.
- **CANsub discovery on macOS is untested with a real device.** Its mDNS browse shares port
  5353 with mDNSResponder through `SO_REUSEPORT`, which works only if mDNSResponder set it too.

## Command-line tools (source checkout only)

**A release bundle does not contain these.** It ships the app (`blobly_net`), the engine as a
library (`libblobly.so` / `blobly.dll`, with `bb.h`) and, on Windows, `canbridge`. Everything
else under `cmd/` is a tool you build from a checkout of the source, set up as in the sections
above (on Windows, the MSYS2 `UCRT64` shell). Where a guide names one of them, this is what it
means. With no checkout, most have a counterpart in what ships: the Discover dialog and the
`vector` / `blobly.vector` scripting calls do what `vectorcheck --assign` does, the Script panel
runs Lua tests, the Python package (`pip install blobly`) and the Replay panel cover the rest bus.

Build a tool from the repository root, then run it:

```sh
v -enable-globals -o build/vectorcheck cmd/vectorcheck     # Windows: -o build/vectorcheck.exe
build/vectorcheck --list
```

or build and run in one step with `v -enable-globals run cmd/<tool> [args]`. Each tool's usage
is the comment at the top of its source file.

| tool | what it does | described in |
|---|---|---|
| `cmd/script` | the headless Lua test runner (usually through `scripts/runtests.sh`) | [scripting.md](scripting.md) |
| `cmd/restbus` | replay a recording onto live buses with the ECU under test subtracted | [rest_bus.md](rest_bus.md), [simulation.md](simulation.md) |
| `cmd/arxml2dbc` | export an AUTOSAR ARXML as a DBC (and a `[[frame]]` fragment for blobly_emb) | [dbc_attributes.md](dbc_attributes.md) |
| `cmd/flash` | flash an image through a blobly_emb bootloader over ISO-TP | [scripting.md](scripting.md) |
| `cmd/lin_monitor` | watch or run a LIN bus, every frame decoded through an LDF | [lin.md](lin.md) |
| `cmd/mf4_dump` | read an ASAM MF4 recording (count, ids, frames) | [streaming_replay.md](streaming_replay.md) |
| `cmd/dbc_decode` | load a DBC and decode one frame | [scripting.md](scripting.md) |
| `cmd/sim_startup_check` | load a project and build its simulated ECUs, with no GUI | [simulation.md](simulation.md) |
| `cmd/project_scaffold` | fill a project file from the interfaces this machine has | [can_hardware.md](can_hardware.md) |
| `cmd/canbridge` | offer a Linux host's CAN interfaces to Blobly Net elsewhere; the Windows bundle carries it for WSL, anywhere else build it with `scripts/build_canbridge.sh` | [wsl_bridge.md](wsl_bridge.md) |
| `cmd/vectorcheck` | bring up a Vector channel, list and assign application channels (Windows) | [windows_can_hardware.md](windows_can_hardware.md) |
| `cmd/kvasercheck` | bring up Kvaser channels and walk CAN-FD data rates (Windows) | [windows_can_hardware.md](windows_can_hardware.md) |
| `cmd/silentcheck` | prove a listen-only wire stops acknowledging, on any two adapters | [windows_can_hardware.md](windows_can_hardware.md) |
| `cmd/crosscheck` | prove two wires are one bus and a frame survives the crossing | [windows_can_hardware.md](windows_can_hardware.md) |
| `cmd/can_smoke` | dump a bus or send one frame | [windows_can_hardware.md](windows_can_hardware.md) |
| `cmd/cansub_smoke` | a CANsub on the wire, end to end | its source header |
| `cmd/doip_smoke` | UDS over DoIP against a local entity, no project needed | [doip.md](doip.md) |
| `cmd/uds_smoke` | drive the UDS client against an ECU | [scripting.md](scripting.md) |
| `cmd/sim_smoke` | run the native simulated ECU and check it end to end | [scripting.md](scripting.md) |
| `cmd/lua_smoke` | the embedded Lua runs a script and calls back into V | [scripting.md](scripting.md) |
| `cmd/isotp_smoke` | send one ISO-TP PDU over the kernel socket and print the reply | its source header |
| `cmd/trace_dump` | read a blobly_emb target's trace ring over ISO-TP | its source header |
| `cmd/loadtest` | a headless benchmark of many concurrent buses | its source header |

`vectorcheck` and `kvasercheck` are Windows tools. A Linux build compiles, but vectorcheck says
its backend is Windows-only, `--list` finds no driver in either, and an open of `vector:1` or
`kvaser:0` goes to SocketCAN, where those are ordinary interface names, and fails as a missing
interface.
`scripts/docs_tools_check.sh` (CI) holds this list to the guides: a guide naming a `cmd/` tool that
is neither in the bundle nor in this table fails it.

## Dependencies

`setup_env.sh` installs these on Linux; the lists are here for anyone building by hand. Plus the
pinned V compiler on all of them.

**Linux** (Debian/Ubuntu), mirroring [`ci.yml`](../.github/workflows/ci.yml):

```sh
sudo apt install g++ pkg-config libglfw3-dev libfreetype-dev libgl1-mesa-dev
```

**Native Windows**, MSYS2 `UCRT64`, mirroring [`windows.yml`](../.github/workflows/windows.yml).
More than the Linux set, because the glyph rasterizer and text stack are not system libraries
there:

```sh
pacman -S git mingw-w64-ucrt-x86_64-{gcc,pkgconf,glfw,freetype,harfbuzz,glib2,fribidi,fontconfig}
```

**macOS**, Homebrew: `brew install glfw freetype pkg-config` (the steps are
[above](#macos-from-source)).
