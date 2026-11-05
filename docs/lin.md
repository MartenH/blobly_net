# LIN

LIN is being added in steps. This page says what exists today and what comes next.

## What exists

- **`blobly/lin`**, the bus. It has its own frame type and its own `Bus` interface, so it is not
  a CAN channel and nothing in the CAN paths changed for it.
  - Protected ids, classic and enhanced checksums (ids 0x3C..0x3F always classic), and frame
    times.
  - A decoder for the byte stream a serial port gives, which a later serial backend uses.
  - `inproc:<name>`, a LIN bus inside the process. It runs on every OS and has:
    - one master per bus;
    - every handle hearing every frame;
    - no-response when no node answers a header;
    - bit-by-bit arbitration when two nodes answer at once, so the winner's frame gets through
      and the loser sees a bit error;
    - injected faults (bad checksum, silent, short);
    - wakeup and go-to-sleep;
    - diagnostic replies (SlaveResp) only from the node the request (MasterReq) addressed.
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

## What comes next

Each step is its own pull request:
1. A serial backend on Linux (`tty:` and `pty:`), so LIN can run over a USB-to-UART adapter or a
   pair of virtual serial ports.
2. A `lin:` section in the project file, brought up by the headless runner, and a Lua `lin.*`
   namespace.
3. The same from C and Python.
4. PEAK PLIN on Windows: the two LIN channels of a PCAN-USB Pro FD.
5. A LIN panel in the GUI.
6. A real LIN node on a system_full board.

Until the LIN panel exists, LIN does not appear in the GUI's trace, its Buses panel or its
recordings.
