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

## What comes next

Each step is its own pull request:
1. A `lin:` section in the project file, brought up by the headless runner, and a Lua `lin.*`
   namespace.
2. The same from C and Python.
3. PEAK PLIN on Windows: the two LIN channels of a PCAN-USB Pro FD.
4. A LIN panel in the GUI.
5. A real LIN node on a system_full board.

Until the LIN panel exists, LIN does not appear in the GUI's trace, its Buses panel or its
recordings.
