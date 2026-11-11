# Network Management

**View ▸ Network Management** shows, for each CAN bus with an NM cluster, who reports in and who
keeps the network awake. The panel only listens. The simulated nodes of a row are what sends NM:
each one the cluster knows announces its PDU on the cluster's cycle while the run is up
([below](#simulated-nodes-announce)).

The frame is AUTOSAR CanNm's default layout, the one blobly_emb's `comm/nm` sends:

| byte | field |
|---|---|
| 0 | the source node id (NID) |
| 1 | the control bit vector: bit 0 repeat-message request, bit 3 ready to sleep, bit 4 active wake-up, bit 6 PN info |
| 2–7 | the partial-network request mask, little-endian, read only when PN info is set |

A node announces on its own CAN id in the cluster's NM range (blobly_emb: `base + NID`). An
empty PDU, or one saying PN info with no mask byte, is counted as malformed.

A 1-byte PDU is the node id alone: a cluster configured with the control bit vector off
(`CanNmPduCbvPosition` = `CANNM_PDU_OFF`) and no user data. Such a node is read with no bits: it
counts as asking for the network while it is heard, releases by falling silent, and never says
active wake-up, so its frame wakes the bus only after a silence. Its bits column stays empty, a
script's `bits` is nil (Lua) or `None` (Python), and `bb_nm_node.has_cbv` is 0. A cluster with the
control bit vector off and user data after the node id is not told apart: its byte 1 is read as
the control bit vector.

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
frames are on the wire, except on PCAN, which does not echo this process's own sends: there the
panel shows what the bus brought, as the J1939 reading does. A wire with an NM configuration
that no enabled row reads during a run is marked as not read, rather than shown asleep. An
imported recording (Trace ▸ Open Recording) gets a reading of its own, per recorded bus, shown
as at its last frame while it is on screen, and never mixed with the live wires.

## Where the NM configuration comes from

Per bus, the first of these that has one:

1. **The system model**: the `system.toml` the Diagnostics and System panels use. A bus with
   `nm = { peers = [0x500, 0x53F], timeout_ms = 300 }` applies to the channel named after it
   (the bus `body` to the channel `body`). Every node on that bus with an `nm` offset is
   declared, and the offset is its NID (`nm = 0x11` announces on `0x511` and is named in the
   table).
2. **The ARXML** loaded for the channel: frames that map an NM-PDU, as their only PDU or
   beside others. Exactly those frames are NM, of either kind, never the ids between them,
   each read from the byte the NM-PDU starts at to its declared length, so padding after it is
   never read as a PN mask. A frame whose sender the file names declares that ECU on it.
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
loaded in the System panel (View ▸ blobly_emb panels) shows its declared nodes, all missing, before anything is heard.
At Start the configuration is fixed for the run.

## Simulated nodes announce

A node the row simulates (`simulate:` or `simulation:`) sends its NM PDU every cycle while the run
is up, in the GUI and headless alike, so a rest bus keeps an ECU under test awake without a
hand-written cyclic frame. The PDU is the node's NID and a control bit vector of 0x00 (the network
requested, nothing else said), in an 8-byte frame (the one blobly_emb's `comm/nm` sends and the
shortest it reads), zeros elsewhere; an ARXML NM-PDU sits at its byte, as long as the file says.

- **Its id and NID** come from the cluster's declaration of that node: the system model (a node on
  the bus with an `nm` offset announces on `lo + offset` with the offset as its NID), or the ARXML
  (the NM frame whose sender is the node, which gives the id and not the NID). What the declaration
  does not state comes from the node's own entry, which is also the whole of it on a cluster that
  declares nobody (a row's own range):

  ```yaml
  channels:
    - name: CAN1
      interface: can0
      nm: { lo: 0x500, hi: 0x53F, timeout_ms: 2000, cycle_ms: 200 }
      simulation:
        - name: BodyController
          nm: { id: 0x511, nid: 0x11 }
  ```

  An id above 0x7FF is a 29-bit frame; `ext: true` says so below it. An id that is not one of the
  cluster's NM frames announces nothing, since nothing would read it.
- **The cycle** is the system model's bus `msg_cycle_ms` (blobly_emb's key, `nm = { peers = [lo,
  hi], timeout_ms = 300, msg_cycle_ms = 100 }`), else a row's `nm:` `cycle_ms`, else for a system
  model's cluster blobly_emb's default, 100 ms (the cycle a node generated from that model takes).
  A row may state the cycle alone, `nm: { cycle_ms: 200 }`, for a cluster a system model or an
  ARXML gives. On an ARXML's cluster or a row's own range with no cycle stated, nothing announces:
  the run says which members would have.

At Start the Log (headless: stdout) names each node announcing, its id, NID and cycle, and says why
a node meant to announce does not. Both keys need schema v13: an older build refuses a range-less
`nm:` and drops the rest on its next save.

A script releases the network for the row's simulated nodes, and they stop announcing, as an
AUTOSAR CanNm node releases by falling silent; a request makes them announce again at once. A run
starts with every node requesting.

```python
with blobly.Project("projects/nm-demo/nm-sim.blobnet") as net:
    nm = net.channels.body.nm()
    nm.release()               # the simulated nodes stop announcing
    nm.expect_asleep(2000)
    nm.request()               # they announce again
```

Lua's `nm.release(channel)` / `nm.request(channel)` and the C ABI's `bb_nm_request(row, request)`
are the same; each is refused while the run is stopped, since the next Start requests the network
for every node again. `projects/nm-demo/nm-sim.blobnet` is the demo: sysnode and domain announce every
100 ms on the ids the system.toml gives them.

## From a script

Python's `ch.nm()` and Lua's `nm.*` read a channel's cluster the way the panel does, from the frames
the script's own handle reads (a frame is consumed once, by whoever reads it, and the script's own
sends are not in it), configured for the channel's wire by the same rule as above, or by a range
the script states. A reading is as of the script's latest read on the channel, and the waits
(`expect_state`, `expect_asleep`) read until the cluster is in a state, kept awake by the nodes
named:

```python
nm = net.channels.body.nm()
nm.expect_state("awake", 3000, kept_awake_by=["sysnode", "domain"])
nm.expect_asleep(30000)
```

[scripting_python.md](scripting_python.md#network-management) and
[scripting.md](scripting.md#network-management--nm) are the references. In the GUI a script's
reading is its own, beside the panel's.

## Demo

```sh
BLOBLY_PROJECT=projects/nm-demo/nm-demo.blobnet ./scripts/run_gui.sh
# ▶ Start, then View ▸ Network Management
```

It replays 40 s of NM traffic, looping, onto an in-process bus. sysnode wakes the bus and domain
joins. A node nothing declares reports for a few seconds, and zone_a never reports. The nodes
then release the bus, which sleeps until domain wakes it again with a PN request.
