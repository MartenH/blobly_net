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
wsl.exe -d <distribution> -u root --cd <canbridge's folder> -- ./canbridge --vcan 2 --connect 127.0.0.1:<port> --token <token> --name <distribution>
```

- `--vcan 2` makes sure `vcan0` and `vcan1` exist and are up (at MTU 72, so they carry CAN-FD),
  creating them if they are missing. That is why it runs as root.
- It then offers **every** CAN and vcan interface the distribution has, so a real `can0` behind
  USB/IP shows up too.
- The bridge **dials the app**: the app listens on `127.0.0.1` and the bridge connects to it with
  a one-time token. WSL's firewall blocks connections *into* the distribution by default and
  lets connections *out* through, so this direction needs no firewall rule and no admin rights.

The `canbridge` beside `blobly_net.exe` is a Linux program. WSL runs it straight from the
Windows folder. The engine looks for it beside itself first (`blobly.dll`, for a library host
such as Python), then beside the executable; with neither, it runs the `canbridge` on the
distribution's PATH.

## From Python

The Windows wheel (`pip install blobly`) carries `canbridge` beside the engine, so a project row
`bridge:Ubuntu-24.04/vcan0` opens from Python as it does in the app. `blobly.bridge` starts, follows
and stops a bridge explicitly ([scripting_python.md](scripting_python.md#the-wsl-bridge)):

```python
from blobly import bridge

print(bridge.distributions())        # ['Ubuntu-24.04']
print(bridge.program())              # ...\site-packages\blobly\_native\canbridge
print(bridge.start("Ubuntu-24.04"))  # ['bridge:Ubuntu-24.04/vcan0', 'bridge:Ubuntu-24.04/vcan1']
bridge.stop("Ubuntu-24.04")
```

No CI runner has WSL, so this is checked by hand, on a Windows machine whose WSL meets the
requirements below:

1. `pip install blobly` (or the wheel CI built) into a fresh venv, and run the lines above. The
   start returns the two vcans, and `bridge.state("Ubuntu-24.04")` is `('connected', '')`.
2. In a WSL terminal run `candump vcan0`, and from Python open the row and send a frame:
   `blobly.Project` over a project with a `bridge:Ubuntu-24.04/vcan0` row, then `ch.send(0x123, b"\x01")`.
   `candump` prints it; a `cansend vcan0 321#02` arrives at `ch.recv(1000)`.
3. `bridge.stop("Ubuntu-24.04")` returns, `state` reads `('idle', '')`, and `ps -e | grep canbridge`
   in WSL finds nothing.
4. In a WSL distribution with no vcan module, `bridge.start` raises with the bridge's own reason
   (*cannot create vcan0 …*).

## Requirements

- **A distribution at least as new as Ubuntu 24.04** (its glibc, precisely): `canbridge` is a
  Linux program built on Ubuntu 24.04 and runs inside the distribution.
- **WSL 2 with `networkingMode=mirrored`** in `%UserProfile%\.wslconfig`:

  ```
  [wsl2]
  networkingMode=mirrored
  ```

  Without it, WSL cannot reach the app on `127.0.0.1`, and the bridge reports that it did not
  dial in.
- **A kernel that can create vcan interfaces.** The stock WSL kernel has no `vcan` module. If
  **Start bridge** reports *"cannot create vcan0 … this kernel has no vcan module loaded"*, open
  a WSL terminal in the app's folder (the bundle ships both scripts) and run:

  ```
  sudo ./scripts/setup_sudoers.sh   # once: lets the two below load the module without a password
  ./scripts/build_vcan_module.sh    # once per WSL kernel: builds and loads the module (a few minutes)
  ./scripts/setup_vcan.sh           # after each WSL restart: loads it and brings vcan0/vcan1 up
  ```

  Interfaces that already exist are used as they are.

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
- **Listen-only** stops the app from sending. It does not stop the controller of a *real*
  `can0` behind a bridge from acknowledging frames. That has to be set in the distribution
  (`ip link set can0 type can listen-only on`), as for any SocketCAN interface (#454). A vcan
  has no controller, so this does not affect vcans.

## When it does not start

A bridge that cannot start tells the app why, and the Discover dialog shows it under **Start
bridge**. A bridge that never dials in is reported after 20 seconds. The usual cause is WSL not
running in mirrored networking mode.

To check the distribution's side by hand, run this from the app's folder in a WSL terminal:

```
sudo ./canbridge --vcan 2 --connect 127.0.0.1:1 --token x
```

It sets up the vcans as **Start bridge** would and prints anything that fails. It then cannot
reach the app, which is expected, because the real port and token are the app's own and change
at every launch. `canbridge --help` lists the options.
