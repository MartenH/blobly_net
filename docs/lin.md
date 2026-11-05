# LIN

LIN is being added in steps. This page says what exists today and what comes next.

## What exists

- **`blobly/lin`**, the bus. It has its own frame type and its own `Bus` interface, so it is not
  a CAN channel and nothing in the CAN paths changed for it.
  - Protected ids, classic and enhanced checksums (ids 0x3C..0x3F always classic), and frame
    times.
  - A decoder for the byte stream a serial port gives (breaks and framing errors marked in it).
  - `inproc:<name>`, a LIN bus inside the process. It runs on every OS and has:
    - one master per bus;
    - every handle hearing every frame;
    - no-response when no node answers a header;
    - bit-by-bit arbitration when two nodes answer at once, so the winner's frame gets through
      and the loser sees a bit error;
    - injected faults (bad checksum, silent, short);
    - wakeup and go-to-sleep;
    - diagnostic replies (SlaveResp) only from the node the request (MasterReq) addressed.
  - A serial backend on Linux:
    - `tty:<path>[@baud]` is a real UART behind a LIN transceiver, for example a USB-to-UART
      adapter. Any rate the adapter can produce works, 10417 baud included; an adapter that
      rounds the rate further than LIN allows (0.5 % for a master, 1.5 % otherwise) is refused
      when the port is opened, naming the rate it took. The master sends the break with the
      port's break control, so its length is set by the host and the adapter: a USB adapter
      makes it longer than the 13 bits asked for. The transceiver echoes everything sent, and
      that echo is how the handle sees its own header and response; a response that comes back
      different is a bit error. A master and a monitor are reliable. A PC acting as a slave
      answers after it has read the header, so whether it meets the master's response time
      depends on the adapter's latency (on an FTDI adapter, set its latency timer to 1 ms): best
      effort.
    - `pty:<path>[@baud]` is a pseudo-terminal, for tests and for talking to another program. A
      pty carries no break, so a break is written as the bytes `FF 00 00` and a data byte 0xFF as
      `FF FF`. Nothing is echoed. A pty has two ends, so a pty bus has two nodes on it.
    - One handle per device in a process; a second open of the same path is refused.
    - A header, a wakeup or a go-to-sleep waits until the previous frame's slot (its longest
      allowed time) has ended, as a LIN master must. A wakeup is a dominant pulse of 250 µs to
      5 ms at every rate.
    - A port that goes away (an adapter unplugged) ends the bus: calls answer that the carrier
      is gone, and a running schedule stops.
    - On other systems a `tty:` or `pty:` address is refused by name.
  - A schedule runner on a fixed time grid.
  - `Row`: one LIN bus with its simulated nodes, its schedule and a live view of every frame id.
- **`blobly/lindb`** reads an LDF (LIN 1.3 to 2.2A). Every value it refuses, and every part it
  does not act on (event-triggered and sporadic frames, configuration commands), is listed in its
  notes rather than dropped silently. `dbc/lin_demo.ldf` is the example file.
- **`lin_monitor`** prints a LIN bus, decoded through an LDF. It can also run a simulated
  cluster on its own:

  ```
  v -enable-globals run cmd/lin_monitor inproc:body --ldf dbc/lin_demo.ldf \
      --role master --simulate CEM,LSM,RSM --schedule NormalTable --seconds 2
  ```

  `--dump-ldf FILE` prints how the LDF was read.

  On Linux, `--pty` makes two linked pseudo-terminals, runs the bus on one and prints the path
  of the other, so another program can attach to it, another `lin_monitor` included:

  ```
  v -enable-globals run cmd/lin_monitor --pty --ldf dbc/lin_demo.ldf --role master \
      --simulate CEM --schedule NormalTable
  # pty: attach to /dev/pts/7 ...
  v -enable-globals run cmd/lin_monitor pty:/dev/pts/7 --ldf dbc/lin_demo.ldf \
      --role slave --simulate LSM
  ```

## In a project

A project's LIN buses are a list of their own, `lin:`, beside `buses:`. A LIN bus is never a row
of `buses:`:

```yaml
lin:
  - name: BODY
    address: inproc:body        # or tty:/dev/ttyUSB0@19200, pty:/dev/pts/4
    bitrate: 19200              # optional: else the address's rate, else the LDF's LIN_speed
    ldf: ../dbc/lin_demo.ldf    # relative to the project file, as a database is
    role: master                # master | slave | monitor (the default)
    simulate: [CEM, LSM, RSM]   # LDF nodes this process plays; the master only as master
    schedule: NormalTable       # the table the master runs from the start
    enabled: true
```

An unknown key, a role that is not one of the three, a missing name or address, two LIN buses of
one name, and a LIN bus named like a channel of `buses:` (scripts name both the same way) are
refused when the project is read (an unknown key only in a file of this build's schema or older;
a newer file opens with the version note). The GUI's Configuration refuses to save or start a
channel renamed like a LIN bus, and a new bus never takes a LIN bus's name. A project with a `lin:` section is written as schema v11; one
without it is written as before.

The headless runner (`cmd/script`, `scripts/runtests.sh`) starts every enabled LIN bus before
the CAN buses and stops it with the run. Its LDF notes are printed like a database's. The GUI
reads and saves the section, but does not run or show the buses yet: Start says so in the Log.
`projects/lin-demo.blobnet` is the example, and `tests/lin.lua` its suite.

## From Lua

`lin.open("BODY")` is a handle on a LIN bus of the run: it reads every frame from then on, and
controls the row (`lin.header`, `lin.set`, `lin.schedule`, ... as its role allows).
`lin.open("inproc:x", { role = "master", ldf = "x.ldf", baud = 19200 })` opens an address as a
bus of the script's own, closed when the script ends; the LDF path is relative to the script. In
the GUI's Script panel `lin.open` takes an address only. The calls are in
[scripting.md](scripting.md#lin--lin).

## What comes next

Each step is its own pull request:
1. The same from C and Python.
2. PEAK PLIN on Windows: the two LIN channels of a PCAN-USB Pro FD.
3. A LIN panel in the GUI.
4. A real LIN node on a system_full board.

Until the LIN panel exists, LIN does not appear in the GUI's trace, its Buses panel or its
recordings.
