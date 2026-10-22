> **What this version's claims rest on.** The protocol engine and the virtual paths
> (simulation, the in-process bus, DoIP, replay) are unit-tested and run in CI on every push.
> **SocketCAN I/O is exercised on the maintainer's bench** (vcan and real adapters), not in
> CI — the CI environment has no vcan. The **Windows vendor CAN backends (Vector, PCAN,
> Kvaser) and the CANsub backend (a USB network adapter, both platforms) are hand-verified
> on real hardware** — Vector on a VN1630A at bus saturation — see
> [windows_can_hardware.md](https://github.com/MartenH/blobly_net/blob/@TAG@/docs/windows_can_hardware.md).
> Vendor DLLs (`vxlapi64.dll`, `PCANBasic.dll`, `canlib32.dll`) are **not bundled** — they
> come with the vendor's driver install, and the Vector XL terms forbid redistributing theirs.
>
> The Linux tar.gz needs the distro runtime: `sudo apt install libglfw3 libfreetype6 libgl1`.
> The Windows zip is self-contained.
>
> The **Python wheels** (`pip install blobly`) carry the engine for Linux x86_64 (a glibc as new
> as Ubuntu 22.04's, or newer) and Windows x64, and CI runs the package's tests against the
> installed wheel on both. There is no source distribution, so on any other platform pip finds
> nothing to install; build the library from a checkout instead
> ([scripting_python.md](https://github.com/MartenH/blobly_net/blob/@TAG@/docs/scripting_python.md)).
