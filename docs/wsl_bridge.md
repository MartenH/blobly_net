# CAN in WSL from the Windows build

The Windows build draws better than the Linux one under WSLg, but Linux virtual CAN interfaces
(`vcan0`, `vcan1`) live inside WSL, along with whatever talks on them: a host build of an ECU, `candump`,
`cangen`. A **CAN bridge** lets the Windows app use them. It is a small program, `canbridge`,
that runs inside the WSL distribution and carries frames between its CAN interfaces and the app.

## Use it

1. **Configuration ▸ Discover…** On Windows the dialog has a **WSL (CAN bridge)** section with
   one line per installed distribution.
2. Press **Start bridge** next to the distribution. Within a second or two its interfaces appear
   in the list above as `bridge:<distribution>/vcan0`, `…/vcan1`, adapter `bridge`.
3. Tick them and **+ Add ticked**, like any other interface.

After that a project just works: the address names the distribution, and **▶ Start** starts the
bridge itself when a channel needs it. Nothing about the connection is saved in the project,
because it changes every time the app starts.

**Disconnect** in the same section ends the bridge (stopped runs only). It also exits by itself
when the app closes.

## What Start bridge does

It runs `canbridge` in the distribution **as root**, with no console window:

```
wsl.exe -d <distribution> -u root --cd <the app's folder> -- ./canbridge --vcan 2 --connect 127.0.0.1:<port> --token <token> --name <distribution>
```

- `--vcan 2` makes sure `vcan0` and `vcan1` exist and are up (at MTU 72, so they carry CAN-FD),
  creating them if they are missing. That is why it runs as root.
- It then offers **every** CAN and vcan interface the distribution has, so a real `can0` behind
  USB/IP shows up too.
- The bridge **dials the app**: the app listens on `127.0.0.1` and the bridge connects to it with
  a one-time token. WSL's firewall blocks connections *into* the distribution by default and
  lets connections *out* through, so this direction needs no firewall rule and no admin rights.

The `canbridge` beside `blobly_net.exe` is a Linux program. WSL runs it straight from the
Windows folder.

## Requirements

- **WSL 2 with `networkingMode=mirrored`** in `%UserProfile%\.wslconfig`:

  ```
  [wsl2]
  networkingMode=mirrored
  ```

  Without it, WSL cannot reach the app on `127.0.0.1`, and the bridge reports that it did not
  dial in.
- **A kernel that can create vcan interfaces.** The stock WSL kernel has no `vcan` module. If
  **Start bridge** reports *"cannot create vcan0 … this kernel has no vcan module loaded"*, set
  vcan up once inside the distribution with `scripts/setup_vcan.sh` (it loads a module built by
  `scripts/build_vcan_module.sh`). Interfaces that already exist are used as they are.

## Limits

- **Sending costs one round trip per frame.** The bridge confirms every frame it puts on the
  interface, so a failed send is reported for that frame. Measured Windows→WSL: about
  **170 µs per frame**, so about 5,000 frames a second per channel. That is plenty for
  diagnostics, Quick Send and generators, but replaying a saturated bus can fall behind.
- **Receiving** keeps up with any real bus (tested at 20,000 frames a second). An unpaced flood
  on a vcan can overflow the bridge's socket, exactly as it overflows any SocketCAN reader.
- **Timestamps** come from the distribution's clock and are placed on the app's timeline like
  any adapter's hardware clock.
- **The bitrate** of a real interface behind a bridge is set in the distribution
  (`ip link set can0 type can bitrate 500000`), not in the project.

## Running a bridge by hand

`canbridge --help` lists the options. The port and token are the app's own and change at every
launch, so by hand is for development. A bridge that cannot start says why to the app, which
shows it in the Discover dialog. A bridge the app turns away exits 1 with the app's reason.
