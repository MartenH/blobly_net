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
