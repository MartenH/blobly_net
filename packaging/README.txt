Blobly Net — a CANoe-style automotive bus tester
=================================================

Run it
------
  1. Double-click  blobly_net.exe
  2. It opens with the driver-free SIMULATION (projects/sim-demo.yml).
     Press  > Start  (top-left) — the Trace fills with decoded CAN frames.
  3. Explore more examples:  File > Open Example  (simulation, replay,
     DoIP diagnostics, CPU-load telemetry).

What's in this folder
---------------------
  blobly_net.exe   the application
  *.dll            runtime libraries — keep them next to the .exe
  projects/        example project .yml files (bus setup + simulation)
  dbc/             CAN databases the examples decode against
  manifests/       telemetry handler manifests (Trace Chart, e.g. trace-demo)
  samples/         demo recordings (.log / .mf4) for File > Open Recording

Project files use the .blobnet extension. To make double-clicking one open it
in Blobly Net (Windows, per-user, no admin):

  powershell -ExecutionPolicy Bypass -File register_blobnet_win.ps1

(Run it from this folder so it finds blobly_net.exe; -Unregister removes it.)

No hardware, driver, or Python is needed for the simulation examples. Real
CAN hardware (Kvaser / PCAN) is supported on Windows — open the in-app Help
(Help panel > Open in browser) for the full guide.

https://github.com/MartenH/blobly_net
