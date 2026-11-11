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
    - `pty:<path>,plain` is a pty that another program writes LIN into the way it would write
      to a UART: the sync byte, PID, data and checksum, with no break and 0xFF as itself. An
      AUTOSAR Lin driver ported to Linux that opens a pty instead of a serial port writes this.
      A sync byte read between frames starts a frame. On a pty the other program is the only
      other node, so when it sends a header it is the master, and it writes its own response
      right behind the header. So a frame whose header came from it ends once 2 ms pass with
      no bytes (20 bit times below 10000 baud). The exception is a header whose length the LDF
      states and whose response has not begun: that waits for its slot, as on a wire. A
      frame ends when it reaches its length, so a sync byte right after it starts the next
      frame. blobly answers in the same plain bytes.
    - Where a pty's path is a regular file, its first line names the device, so a program that
      writes the path of the pty it made (`/tmp/lin_slave_0` holding `/dev/pts/7`) can be
      named the same way every run: `pty:/tmp/lin_slave_0,plain`. A file older than the device
      it names is refused: the pty it was written for is gone, and its number may now be
      somebody's terminal.
    - One handle per device in a process; a second open of the same path is refused.
    - A header, a wakeup or a go-to-sleep waits until the previous frame's slot (its longest
      allowed time) has ended, as a LIN master must. A wakeup is a dominant pulse of 250 µs to
      5 ms at every rate. On a pty a wakeup written right after another waits 150 ms, the gap a
      LIN node leaves before repeating one, so the other end has read the first as a wakeup.
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

A LIN bus is a row of `buses:` with `adapter: lin`:

```yaml
buses:
  - name: BODY
    adapter: lin
    address: inproc:body        # or tty:/dev/ttyUSB0@19200, pty:/tmp/lin_slave_0,plain
    bitrate: 19200              # optional: else the address's rate, else the LDF's LIN_speed
    ldf: ../dbc/lin_demo.ldf    # relative to the project file, as a database is
    role: master                # master | slave | monitor (the default)
    simulate: [CEM, LSM, RSM]   # LDF nodes this process plays; the master only as master
    schedule: NormalTable       # the table the master runs from the start
    enabled: true
```

Its interface is `lin:<address>` (`interface: lin:inproc:body` is the same row), and its kind is
LIN: it has no generators, simulated CAN nodes or databases, and nothing that reads CAN frames
reads it. A key a LIN row has no use for, a role that is not one of the three, a missing name or
address, and a LIN row whose name another row carries (a script opens a LIN bus by its name) are
refused when the project is read (an unknown key only in a file of this build's schema or older;
a newer file opens with the version note). The GUI's Configuration refuses to save or start a row
renamed like a LIN bus, and a new bus never takes a taken name. A project with a LIN row is
written as schema v12; one without is written as before.

A v11 file's top-level `lin:` list, the form LIN v1 used, is read into rows of this shape and
saved as rows.

The headless runner (`cmd/script`, `scripts/runtests.sh`) starts every enabled LIN bus before
the CAN buses and stops it with the run. Its LDF notes are printed like a database's.
`projects/lin-demo.blobnet` is the example, and `tests/lin.lua` its suite.

## In the GUI

Start runs every enabled LIN bus too, and Stop ends it. Each bus is shown in **View ▸ LIN**, and
its LDF notes go to the Log:
- a header line: the bus's state (active or asleep), rate and load, and the schedule's progress
  (headers sent, slots that started late, headers the bus refused);
- a master's controls: run a schedule table of the LDF, stop it, go to sleep, wakeup (a slave
  has wakeup only, a monitor nothing);
- a table with a row per frame id seen: its LDF name, count, errors, cadence, the last frame
  with its origin (`TX-S` our simulation, `TX` our tester, `RX` another node) and its signals;
- **simulated signals**: what the row's simulated nodes publish, one value each, set by typing
  a value and Enter. A value is typed as it is shown: a number (physical where the signal has
  a physical range, else raw), a logical value's text, a byte array's bytes in hex. `raw:N`,
  `phys:X`, `text:...` and `bytes:01 02` say which. It goes out from the next response;
- the last 500 frames, newest first.

A script run from the Script panel while the run is on reaches its LIN buses by name.

A LIN bus is in the Buses panel, in a LIN group, running while its bus is up. Its frames are in
the trace beside the CAN ones, under the bus's name:
- the id column reads `LIN 0x21` (`LIN —` where the record names no frame: a wakeup, or a header
  that broke before its id), the name is the
  LDF's, and the origin is who published the response (`TX-S` our simulation, `TX` our tester,
  `RX` another node);
- the flags column is the checksum model, an event (`wakeup`, `sleep`), `no response`, and each
  error as `!name`; a frame with an error is grouped apart from the good ones of its id;
- an expanded group shows the frame's signals, decoded through the LDF its bus read it through;
  a frame with an error is not decoded, and its group says why;
- the bus's `last RX` and the RX counts move only for an error-free response another node published,
  so the master's own unanswered headers never make a dead slave look alive.

A LIN frame is not a CAN frame to anything that reads one: the trace's filter, a plot, Send and a
DBC decode leave it alone. LIN is not recorded yet: a recording holds CAN frames, and the Log says
so when one is made while a LIN bus runs.

## From Lua

`lin.open("BODY")` is a handle on a LIN bus of the run: it reads every frame from then on, and
controls the row (`lin.header`, `lin.set`, `lin.schedule`, ... as its role allows).
`lin.open("inproc:x", { role = "master", ldf = "x.ldf", baud = 19200 })` opens an address as a
bus of the script's own, closed when the script ends; the LDF path is relative to the script. In
the GUI's Script panel a name reaches the running run's LIN buses. The calls are in
[scripting.md](scripting.md#lin--lin).

## From C and Python

The C ABI's LIN block (`cmd/libblobly/bb.h`) is `bb_lin_count` / `bb_lin_info` / `bb_lin_text`
over the run's LIN buses, and `bb_lin_open`: a tap on one of them (row >= 0), or a bus of the
handle's own on an address (row -1) with or without a project. A handle reads every frame
(`bb_lin_recv`, a `bb_lin_frame` with its errors as `BB_LIN_ERR_*` bits), decodes one through the
LDF (`bb_lin_decode`, then `bb_lin_signal_info` / `_signal_text` / `_signal_bytes` by index),
controls the bus as its role allows (`bb_lin_header`, `bb_lin_set_signal`, `bb_lin_schedule`,
`bb_lin_stop_schedule`, `bb_lin_wakeup`, `bb_lin_sleep`), reads its view (`bb_lin_read_status`,
`bb_lin_status_id`, `bb_lin_status_text`) and counts (`bb_lin_diagnostics`), and is let go by
`bb_lin_close`, which may come from another thread and ends a receive there.

From Python, `net.lin.BODY` is a `LinBus` on a run's bus and `blobly.lin.open("inproc:x",
"master", ldf="x.ldf")` one of the script's own; `recv`, `expect` (by id or frame name, its
`Timeout` naming what came instead), `set`, `header`, `schedule`, `sleep`, `wakeup`, `status`. The
calls are in [scripting_python.md](scripting_python.md#lin), and
[python/examples/lin_monitor.py](../python/examples/lin_monitor.py) is a complete script.

## What comes next

Each step is its own pull request:
1. LIN in recordings.
2. PEAK PLIN on Windows: the two LIN channels of a PCAN-USB Pro FD.
3. A real LIN node on a system_full board.
