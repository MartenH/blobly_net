Blobly Net — a conventional automotive bus tester
=================================================

Run it
------
  Windows:  double-click  blobly_net.exe
  Linux:    ./blobly_net   (needs the distro's GLFW/FreeType/GL runtime:
            Debian/Ubuntu:  sudo apt install libglfw3 libfreetype6 libgl1)

  1. It opens with the driver-free SIMULATION (projects/sim-demo.blobnet).
     Press  > Start  (top-left) — the Trace fills with decoded CAN frames.
  2. Explore more examples in projects/: simulation, replay, DoIP
     diagnostics, CPU-load telemetry.

Which version is this?
----------------------
  VERSION.txt in this folder, and the window title bar. On Linux
  `./blobly_net --version` prints it; the Windows exe is a GUI-subsystem
  program, so pipe it:  blobly_net.exe --version | more

What's in this folder
---------------------
  blobly_net[.exe]  the application
  *.dll             (Windows) runtime libraries — keep them next to the .exe
  projects/         example .blobnet projects (bus setup + simulation)
  dbc/              CAN databases the examples decode against
  manifests/        telemetry handler manifests (Trace Chart, e.g. trace-demo)
  samples/          demo recordings (.log / .mf4) for File > Open Recording
  tests/            Lua test scripts the Lua panel can run
  docs/             the guides the in-app Help panel renders

To make double-clicking a .blobnet file open it in Blobly Net (Windows,
per-user, no admin):

  powershell -ExecutionPolicy Bypass -File register_blobnet_win.ps1

(Run it from this folder so it finds blobly_net.exe; -Unregister removes it.)

No hardware, driver, or Python is needed for the simulation examples. Real
CAN hardware is supported: SocketCAN on Linux; Vector, PCAN and Kvaser on
Windows — the vendor's own driver install provides their DLLs, which are
deliberately NOT bundled here. Open the in-app Help for the full guide.

https://github.com/MartenH/blobly_net
