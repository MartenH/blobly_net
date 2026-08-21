> **What this version's claims rest on.** The protocol engine and the virtual paths
> (simulation, SocketCAN/vcan, the in-process bus, DoIP, replay) are unit-tested and run in CI
> on every push. The **Windows vendor CAN backends (Vector, PCAN, Kvaser) are hand-verified on
> real hardware** — Vector on a VN1630A at bus saturation — not CI-verified; see
> [windows_can_hardware.md](docs/windows_can_hardware.md). Vendor DLLs (`vxlapi64.dll`,
> `PCANBasic.dll`, `canlib32.dll`) are **not bundled** — they come with the vendor's driver
> install, and the Vector XL terms forbid redistributing theirs.
>
> The Linux tar.gz needs the distro runtime: `sudo apt install libglfw3 libfreetype6 libgl1`.
> The Windows zip is self-contained (mingw runtime DLLs included).
