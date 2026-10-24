# Network Management

**View ▸ Network Management** shows, for each CAN bus with an NM cluster, who reports in and who
keeps the network awake. It only listens: Blobly Net sends no NM frames.

The frame is AUTOSAR CanNm's default layout, the one blobly_emb's `comm/nm` sends:

| byte | field |
|---|---|
| 0 | the source node id (NID) |
| 1 | the control bit vector: bit 0 repeat-message request, bit 3 ready to sleep, bit 4 active wake-up, bit 6 PN info |
| 2–7 | the partial-network request mask, little-endian, read only when PN info is set |

A node announces on its own CAN id in the cluster's NM range (blobly_emb: `base + NID`). A
frame shorter than 2 bytes, or one saying PN info with no mask byte, is counted as malformed.

Bit 3 is read as blobly_emb uses it: a node that has released the network says so and keeps
announcing. In AUTOSAR CanNm, bit 3 is the coordinator's sleep-ready bit, and a node releases
the network by falling silent. The panel reads that silence past the timeout, so an AUTOSAR
cluster goes from awake to asleep without passing through releasing.

## What the panel shows

One section per bus, headed by:

- the bus state: **awake** while a node heard within the timeout asks for the network (ready to
  sleep clear), **releasing** when every node heard within the timeout is ready to sleep,
  **asleep** when nothing has been heard for longer than the timeout;
- **kept awake by**: the nodes heard within the timeout with ready to sleep clear;
- **woken by**: the node whose frame ended the last silence, and whether it said active wake-up.
  The first frame heard counts only if it says active wake-up, since the bus may have been
  awake before listening began;
- who asks for a repeat, and how long since the last NM frame.

Then a table, one row per node: its name (from the system model or the ARXML, else `NID 0x13`),
its NM id, when it was last heard (dim once past the timeout), its cadence (the mean interval,
leaving out a gap longer than the timeout, which is the network asleep, not the node's cycle,
and the last interval), its frame count, its control bits in words (wants network / ready to
sleep, active wake-up, repeat request) and its PN request when it makes one. The last column is a
60 s timeline: green while the node asks for the network, grey while it is ready to sleep, empty
while it is silent. A node keeps its state for the timeout after its last frame.

- **missing**: a node the configuration declares on the cluster that has never reported.
- **unknown**: a reporter the configuration does not declare. A declaration states a NID, a
  CAN id or both, and a reporter must match every one it states, so a node announcing on
  another node's id or with another node's NID is unknown. Only a configuration that declares
  members (a system model or an ARXML naming its senders) makes anyone unknown.

The trackers start over at every Start. A replayed recording reads like live traffic, since its
frames are on the wire. An imported recording (Trace ▸ Open Recording) gets a reading of its
own, per recorded bus, shown as at its last frame while it is on screen.

## Where the NM configuration comes from

Per bus, the first of these that has one:

1. **The system model**: the `system.toml` the Diagnostics and System panels use. A bus with
   `nm = { peers = [0x500, 0x53F], timeout_ms = 300 }` applies to the channel named after it
   (the bus `body` to the channel `body`). Every node on that bus with an `nm` offset is
   declared, and the offset is its NID (`nm = 0x11` announces on `0x511` and is named in the
   table).
2. **The ARXML** loaded for the channel: frames whose PDU is an NM-PDU. Their ids give the
   range, and a frame whose sender the file names declares that ECU at that id.
3. **The channel's own setting** in the project, which gives a range and a timeout and no
   names. It comes last, so a system model or an ARXML for the same bus replaces it (the
   header names the source):

   ```yaml
   channels:
     - name: CAN1
       interface: can0
       nm: { lo: 0x500, hi: 0x53F, timeout_ms: 300 }
   ```

   A range above 0x7FF is read as 29-bit frames; `ext: true` says so for a 29-bit cluster on
   lower ids. It needs schema v10: an older build drops the key on its next save.

A bus with none of these has no NM reading. Nothing guesses that a frame is NM from its id or its
bytes. A range above 0x7FF is read as 29-bit frames. A system model without a stated timeout
gets 300 ms. An ARXML cluster gets 2 s, since the system description does not carry CanNm's
timeout. The header says when the timeout is a default.

While stopped, the open panel follows the configuration once a second, so a `system.toml`
loaded in the System panel shows its declared nodes, all missing, before anything is heard.
At Start the configuration is fixed for the run.

## Demo

```sh
BLOBLY_PROJECT=projects/nm-demo/nm-demo.blobnet ./scripts/run_gui.sh
# ▶ Start, then View ▸ Network Management
```

It replays 40 s of NM traffic, looping, onto an in-process bus. sysnode wakes the bus and domain
joins. A node nothing declares reports for a few seconds, and zone_a never reports. The nodes
then release the bus, which sleeps until domain wakes it again with a PN request.
