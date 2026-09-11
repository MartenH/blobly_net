// software.v — a pure-V ISO-TP (ISO 15765-2) state machine over any transport.Bus.
//
// Unlike kernel_linux.v (which offloads segmentation to the kernel CAN_ISOTP
// socket), this implements SF/FF/CF/FC in software, so it runs on ANY bus backend
// — the in-process simulation bus, the UDP software bus, or (later) a Windows
// vendor driver that has no kernel ISO-TP. Cross-platform (unsuffixed file). It
// implements the same `Channel` interface, so UDS rides on it unchanged.
//
// Scope: classic addressing, single + multi-frame, 8-byte padded frames. Flow control is
// HONOURED on the send side — CTS/WAIT/OVERFLOW, block size and STmin (#226) — because
// `isotp.open` routes here on every non-Linux host, so this is what flash, the shell, scripts
// and the GUI's diagnostics use against real ECUs on Windows; "fine in-process" stopped being
// the whole story when that landed. What this channel SENDS as a receiver is still the
// permissive answer (CTS, block size 0, STmin 0): it asks for no pacing, which is the one thing
// a receiver may always do, and the read side is bounded by recv's own deadline instead.
module isotp

import time
import transport

// Post-error rx flush bounds: after a failed reassembly, drain queued frames until this quiet
// window elapses (no frame), capped at one over-long transfer's worth of frames. See flush_rx.
const flush_quiet_ms = 30
const flush_max_frames = max_pdu / 7 + 2

pub struct SoftChannel {
pub:
	iface string
	tx_id u32
	rx_id u32
	ext   bool
mut:
	bus transport.Bus
	// scanned counts frames a zero-timeout receive has looked past, across every rx_raw call it
	// makes: the bound must cover the whole receive, or a stream of stale Consecutive Frames on
	// our own id restarts the count each time (codex round 17 on #225). Reset at each recv.
	scanned int
	// A segmented send ended badly and the peer may still be sending Flow Control for it. The
	// NEXT segmented send must not read those as answers to its own First Frame — a leftover
	// WAIT would spend the new transfer's budget, and a leftover CTS would authorise Consecutive
	// Frames before the receiver had accepted anything (codex on #226). recv() skipping orphan
	// FCs does not cover this: the usual retry calls send(), not recv().
	//
	// A FLAG RATHER THAN AN UNCONDITIONAL DRAIN, because draining before every segmented send
	// would also discard a reply the caller has not read yet — a legitimate thing to have
	// queued, and nothing to do with this.
	//
	// SET by a segmented send that ended badly, CLEARED by the drain it causes — or by a
	// successful recv(), which means a message got through and the orphans ahead of it were
	// skipped, so the abort is no longer the most recent thing that happened here (#296).
	// Without that second exit the flag outlived its abort: a failed transfer, a short exchange
	// the caller read a reply to, and then a segmented send whose drain discarded a LATER reply,
	// which is exactly what the flag exists to avoid.
	fc_dirty bool
}

// open_software wraps a freshly opened bus on `iface` as an ISO-TP channel that
// sends on tx_id and receives on rx_id.
pub fn open_software(iface string, tx_id u32, rx_id u32, ext bool) !&SoftChannel {
	check_ids(iface, tx_id, rx_id, ext)!
	bus := transport.open(iface)!
	return on_bus(bus, iface, tx_id, rx_id, ext)
}

// on_bus wraps an ALREADY-OPEN bus, for a caller that needs to see the CAN frames this channel
// puts on the wire — the GUI attributes every frame it emits, and a diagnostic server that
// opened its own bus privately would be the one emitter it could not account for.
pub fn on_bus(bus transport.Bus, iface string, tx_id u32, rx_id u32, ext bool) !&SoftChannel {
	return &SoftChannel{
		iface: iface
		tx_id: tx_id
		rx_id: rx_id
		ext:   ext
		bus:   bus
	}
}

// send segments `data` into ISO-TP frames: a Single Frame for ≤7 bytes, else a
// First Frame + (after a Flow Control) Consecutive Frames.
pub fn (mut c SoftChannel) send(data []u8) ! {
	// AN EMPTY PDU IS REFUSED HERE AS THE KERNEL REFUSES IT: encoded, it is a Single Frame with
	// SF_DL 0, which no receiver accepts, and a platform-transparent open() must not transmit it
	// on one platform only (codex round 2 on #225).
	if data.len == 0 {
		return error('isotp send: empty pdu')
	}
	if data.len > max_pdu {
		return error('ISO-TP PDU too large: ${data.len} > ${max_pdu}')
	}
	if data.len <= 7 {
		mut sf := [u8(data.len)] // SF: PCI 0x0<len>
		sf << data
		// NO DRAIN ON THIS PATH. A Single Frame leaves the peer with nothing more to say, so
		// there is no Flow Control conversation to protect — and draining here would block for a
		// quiet window and DISCARD whatever is queued on rx_id, on a path that was immediate and
		// non-destructive. On uds.Server.serve that is a client's retransmitted request, and a
		// run worker parked past the 1500 ms drain budget. The window is ended by a successful
		// recv instead; see fc_dirty.
		return c.tx(sf)
	}
	// BEFORE THE FIRST FRAME, so nothing this drops can be an answer to it: whatever arrives
	// until it goes out belongs to the send that ended badly (see fc_dirty).
	//
	// A QUIET WINDOW, not a snapshot of what is queued right now. The first cut read what had
	// already arrived and went straight on, so a stale Flow Control still in flight — the peer
	// was mid-burst when N_WFTmax gave up — landed after the drain and was consumed by the new
	// transfer's wait, authorising Consecutive Frames the receiver had not asked for. The test
	// written for it slept 30 ms before retrying, which is the tell: it avoided the race rather
	// than covering it (codex on #226).
	//
	// AND IT IS A MITIGATION, NOT A PROOF, which is worth saying plainly: an ISO-TP Flow Control
	// carries no transfer identity, so one arriving after the window is indistinguishable from
	// this transfer's own. Nothing in the protocol can separate them; the window makes the case
	// unlikely and bounded, and there is no version of this that makes it impossible.
	//
	if c.fc_dirty {
		c.flush_rx()
		c.fc_dirty = false
	}
	// First Frame: PCI 0x1<len_hi><len_lo> + first 6 bytes.
	mut ff := [u8(0x10 | u8((data.len >> 8) & 0x0F)), u8(data.len & 0xFF)]
	ff << data[..6]
	c.tx(ff)!
	// From here the peer is answering us, so every exit owes the next send a clean slate.
	c.send_segmented(data) or {
		c.fc_dirty = true
		return err
	}
}

// send_segmented is everything after the First Frame: the Flow Control conversation and the
// Consecutive Frames it authorises. Split out so `send` can mark the channel dirty on ANY exit
// from it — there is no path out of here that leaves the peer with nothing more to say.
fn (mut c SoftChannel) send_segmented(data []u8) ! {
	mut fc := c.await_flow_control()!
	mut sn := u8(1)
	mut off := 6
	// When the last Consecutive Frame went out, in monotonic NANOSECONDS. Zero until the first.
	//
	// MEASURED FROM THE FRAME, NOT COUNTED WITHIN A BLOCK. The first cut slept only when it had
	// already sent one in this block, on the reasoning that the Flow Control opening a block is
	// itself the separation — which sounded right and is not: ISO 15765-2 exempts nothing at a
	// block boundary, and with BS=1 EVERY frame is the first of its block, so a receiver asking
	// for 20 ms got frames as fast as it could answer, around ten times its rate. The clock also
	// pays for the round trip: what the receiver asked for is a gap between frames on the wire,
	// so time already spent waiting for its Flow Control counts towards it.
	//
	// Nanoseconds because STmin has a sub-millisecond scale (0xF1..0xF9 is 100..900 us) that a
	// millisecond tick cannot measure at all.
	mut last_cf_ns := u64(0)
	for off < data.len {
		// One BLOCK: `block_size` Consecutive Frames, or the whole remainder when it is 0.
		mut in_block := 0
		for off < data.len {
			if last_cf_ns != 0 && fc.stmin_us > 0 {
				elapsed_us := i64((time.sys_mono_now() - last_cf_ns) / 1_000)
				remain_us := i64(fc.stmin_us) - elapsed_us
				if remain_us > 0 {
					// Through pacing_sleep_us: a sub-millisecond wait is not one on Windows,
					// which is the platform this state machine is for.
					time.sleep(pacing_sleep_us(int(remain_us)) * time.microsecond)
				}
			}
			n := if data.len - off > 7 { 7 } else { data.len - off }
			mut cf := [u8(0x20 | (sn & 0x0F))]
			cf << data[off..off + n]
			c.tx(cf)!
			last_cf_ns = time.sys_mono_now()
			sn = (sn + 1) & 0x0F
			off += n
			in_block++
			if fc.block_size > 0 && in_block >= int(fc.block_size) {
				break
			}
		}
		if off < data.len {
			// The block is full and there is more: the receiver owes another Flow Control.
			fc = c.await_flow_control()!
		}
	}
}

// await_flow_control waits for one usable Flow Control and returns what it asked for.
//
// WAIT IS THE REASON THIS IS A LOOP. A receiver that is not ready answers 0x31 and another FC
// follows, so each one re-arms the window rather than eating into the first — which is also why
// it must be counted: a peer answering every request with WAIT never trips a timeout, because a
// frame keeps arriving, and without n_wft_max `send` would block for as long as it kept doing it.
//
// STALE CONSECUTIVE FRAMES ARE SKIPPED: a transfer this channel abandoned on its deadline can
// still be arriving when the caller sends the next request, and the first frame met while waiting
// for Flow Control was one of them — "expected Flow Control" for a peer that had not answered yet
// (codex round 11 on #225).
fn (mut c SoftChannel) await_flow_control() !FlowControl {
	// COUNTED PER WAIT, not per transfer, which is what ISO's N_WFTmax bounds: a receiver that
	// asks to wait, is given time, then accepts a block, has done nothing wrong — and a counter
	// carried across blocks would abort a long, legitimately paced transfer partway through.
	mut waits := 0
	for {
		deadline := time.ticks() + fc_timeout_ms
		mut raw := []u8{}
		for {
			rem := int(deadline - time.ticks())
			if rem <= 0 {
				return error('timeout')
			}
			raw = c.rx_raw(rem)!
			if raw.len >= 1 && (raw[0] & 0xF0) == 0x20 {
				continue
			}
			break
		}
		fc := parse_flow_control(raw)!
		match fc.status {
			.cts {
				return fc
			}
			.overflow {
				// The receiver cannot take this PDU at all — it said so rather than dropping it,
				// and retrying the same transfer would get the same answer. Reported as the peer's
				// refusal, not as a timeout, because the two want different things from the caller.
				return error('ISO-TP: receiver reported overflow — the PDU does not fit its buffer')
			}
			.wait {
				waits++
				if waits > n_wft_max {
					return error('ISO-TP: receiver asked to wait ${waits} times (N_WFTmax ${n_wft_max}) — giving up')
				}
			}
		}
	}
	return error('unreachable')
}

// recv reassembles one ISO-TP PDU (SF directly; FF → send FC → collect CFs).
// diagnostics is the bus's: what it dropped or the controller reported is what this channel's
// PDUs were riding (#213).
pub fn (mut c SoftChannel) diagnostics() transport.BusDiagnostics {
	return c.bus.diagnostics()
}

pub fn (mut c SoftChannel) recv(timeout_ms int) ![]u8 {
	// ONE DEADLINE FOR THE WHOLE PDU. Each Consecutive Frame used to get the full timeout afresh,
	// so a peer stalling just under it between frames made request(..., 2000) wait many times
	// two seconds, where the kernel channel bounds the reassembled PDU (codex round 3 on #225).
	// Negative is "forever", as everywhere else.
	deadline := time.ticks() + i64(timeout_ms)
	c.scanned = 0
	mut first := []u8{}
	// What the skip below swallowed, so a timeout can say so (#296). Read as a message, an
	// orphan Flow Control used to surface as `unexpected PCI 0x31`; skipping it is right, but it
	// turned a diagnosable peer into a bare `timeout` — the one answer that says nothing about
	// what is on the wire. The frames are still dropped; only the SILENCE is explained.
	mut orphan_fc := 0
	mut orphan_pci := u8(0)
	for {
		mut rem := timeout_ms
		if timeout_ms >= 0 {
			rem = int(deadline - time.ticks())
			// A zero timeout keeps polling past stale Consecutive Frames as well: the poll ends
			// when rx_raw reports the bus empty, not after the first frame it had to drop (codex
			// round 13 on #225). A positive timeout expires by the clock.
			if rem <= 0 && timeout_ms > 0 {
				return error(orphan_note('timeout', orphan_fc, orphan_pci))
			}
			if rem < 0 {
				rem = 0
			}
		}
		// THE TIMEOUT USUALLY COMES FROM HERE, not from the deadline check above: a caller with
		// time left blocks inside rx_raw and that call is what expires. Decorating only the
		// check left the diagnostic unreachable on the ordinary path (#296).
		first = c.rx_raw(rem) or { return error(orphan_note(err.msg(), orphan_fc, orphan_pci)) }
		if first.len < 1 {
			return error('ISO-TP: empty frame')
		}
		// A CONSECUTIVE FRAME WITH NO TRANSFER IN PROGRESS IS A STALE TAIL, not a message: the
		// rest of a transfer this channel abandoned on its deadline, still arriving from a peer
		// that did not know. A flush at abort time cannot catch frames that have not arrived
		// yet, so they are dropped HERE, where the next reply is awaited (codex round 4 on
		// #225; the first cut flushed and the test proved it insufficient).
		//
		// AND SO IS AN ORPHAN FLOW CONTROL, for the same reason and by the same remedy (#226).
		// This side never expects one — it SENDS Flow Control as a receiver and reads it only
		// while segmenting — so a 0x3x arriving where a First or Single Frame is awaited is
		// left over from a send that ended without consuming it: the peer's second WAIT after
		// N_WFTmax gave up, or the frames queued behind an OVERFLOW. Those aborts are new, so
		// this leftover is new: the old send accepted the first 0x3x it saw and there was never
		// a second one to strand. Read as a message it surfaced as `unexpected PCI 0x31` in
		// place of the next reply (codex on #226).
		if (first[0] & 0xF0) == 0x20 || (first[0] & 0xF0) == 0x30 {
			if (first[0] & 0xF0) == 0x30 {
				orphan_fc++
				orphan_pci = first[0]
			}
			continue
		}
		break
	}
	// THE ABORT IS NO LONGER THE MOST RECENT THING ON THIS CHANNEL (#296). A message read here
	// means every orphan Flow Control queued ahead of it has been skipped by the loop above, so
	// the next segmented send has nothing to drain — and must not drain, or it discards a reply
	// the caller has not read, which is the harm a flag was chosen over an unconditional drain
	// to avoid. Cleared HERE and not at the next send of any shape: a send cannot know whether
	// what is queued is stale, and a drain in front of a Single Frame is destructive on a path
	// that was neither slow nor destructive.
	//
	// It trades one protection for another, deliberately: an orphan arriving AFTER this recv is
	// no longer caught by a later drain. The window was already a mitigation and not a proof —
	// an ISO-TP Flow Control carries no transfer identity — and an abort three exchanges old is
	// not what it was written for.
	c.fc_dirty = false
	pci := first[0] & 0xF0
	if pci == 0x00 {
		len := int(first[0] & 0x0F)
		if len > 7 {
			// Classic ISO-TP: a Single Frame carries at most seven bytes; anything above is not one
			// (codex round 14 on #225).
			return error('ISO-TP: Single Frame length ${len} exceeds 7')
		}
		if len == 0 {
			// SF_DL 0 is invalid on the wire; the send side refuses to produce one, and the receive
			// side must not present it as an empty reply (codex round 9 on #225).
			return error('ISO-TP: empty Single Frame')
		}
		if 1 + len > first.len {
			return error('ISO-TP SF length ${len} exceeds frame')
		}
		return first[1..1 + len].clone()
	}
	if pci == 0x10 {
		if first.len != 8 {
			// A First Frame carries exactly six initial payload bytes on a classic channel: shorter,
			// those bytes would be taken from the Consecutive Frames instead -- a shifted PDU
			// returned as valid (codex round 14 on #225); longer, an FD-sized frame on our id could
			// complete a PDU on its own (codex round 18).
			return error('ISO-TP FF too short')
		}
		total := (int(first[0] & 0x0F) << 8) | int(first[1])
		if total <= 7 {
			// A length that fits a Single Frame must be sent as one (ISO 15765-2); accepted, a
			// total of 0..6 returned the padding bytes as a PDU and 7 waited for a Consecutive
			// Frame that never comes (codex round 7 on #225).
			return error('ISO-TP FF declares ${total} bytes, which must be a Single Frame')
		}
		mut out := []u8{cap: total}
		out << first[2..]
		c.tx([u8(0x30), 0, 0])! // Flow Control: CTS, block size 0, STmin 0
		// Collect Consecutive Frames, validating the 4-bit sequence number. A gap (dropped frame)
		// or a non-CF (the *next* message's FF arriving because this transfer lost a frame) is a
		// clean error rather than silently absorbing it — which used to corrupt this block AND eat
		// the next block's First Frame, surfacing later as a spurious "unexpected PCI" on the next
		// recv(). The caller re-issues the transfer; a hard error beats silent misassembly.
		mut sn := u8(1)
		for out.len < total {
			mut rem := timeout_ms
			if timeout_ms > 0 {
				rem = int(deadline - time.ticks())
				if rem <= 0 {
					// No flush: a flush waits a quiet window per frame and a slow peer renews it
					// indefinitely past the deadline (codex round 5 on #225). The stale tail is
					// dropped where the next reply is awaited instead.
					return error('timeout')
				}
			}
			// A zero timeout collects what is already queued, Consecutive Frames included: rx_raw(0)
			// reads until the bus is empty (codex round 14 on #225).
			cf := c.rx_raw(rem)! // the tail is dropped at the next first-frame wait, not flushed
			if cf.len < 1 {
				continue // empty/padding read — ignore
			}
			if (cf[0] & 0xF0) != 0x20 {
				// No flush here either: its quiet window renews per frame past the deadline (codex
				// round 8 on #225). The aborted transfer's tail is dropped at the next first-frame
				// wait, which is what resyncs a reused channel.
				return error('ISO-TP: expected Consecutive Frame, got PCI 0x${cf[0]:02X} mid-reassembly (a frame was lost)')
			}
			if (cf[0] & 0x0F) != sn {
				return error('ISO-TP: CF sequence gap — got SN ${cf[0] & 0x0F}, expected ${sn} (a frame was lost)')
			}
			if cf.len > 8 {
				// Classic ISO-TP: seven payload bytes per Consecutive Frame; an FD-sized frame on our
				// id is not one of ours (codex round 17 on #225).
				return error('ISO-TP: Consecutive Frame of ${cf.len} bytes on a classic channel')
			}
			if cf.len < 8 && out.len + cf.len - 1 < total {
				// Only the LAST Consecutive Frame may be short; a short one with more of the PDU
				// still to come would have its missing bytes filled from the next frame — a
				// shifted PDU returned as valid (codex round 16 on #225).
				return error('ISO-TP: short Consecutive Frame (${cf.len - 1} bytes) with ${total - out.len} still to come')
			}
			sn = (sn + 1) & 0x0F
			out << cf[1..]
		}
		return out[..total].clone()
	}
	return error('ISO-TP: unexpected PCI 0x${first[0]:02X}')
}

pub fn (mut c SoftChannel) close() {
	c.bus.close()
}

// tx pads an ISO-TP payload to 8 bytes (classic CAN) and sends it on tx_id.
fn (mut c SoftChannel) tx(payload []u8) ! {
	mut data := payload.clone()
	for data.len < 8 {
		data << 0
	}
	c.bus.send(transport.CanFrame{
		id:       c.tx_id
		extended: c.ext
		data:     data
	})!
}

// rx_raw returns the data of the next frame addressed to rx_id within the timeout.
// drain_quiet reads and discards rx-id frames until the bus has been quiet on that id for
// quiet_ms — used to flush a stale in-flight transfer (e.g. a timed-out dump still streaming)
// before re-requesting, so the next recv() starts on a fresh First Frame.
pub fn (mut c SoftChannel) drain_quiet(quiet_ms int) {
	for {
		_ := c.rx_raw(quiet_ms) or { return } // quiet window reached — done
	}
}

// zero_poll_scan_frames bounds how many frames for other ids a zero-timeout poll looks past
// before it reports nothing: a finite backlog is crossed, an endless one is not waited out.
const zero_poll_scan_frames = 4096

// A frame is ours when its id, its WIDTH and its kind match: a remote request on our id carries
// no data and is not ISO-TP (codex rounds 18 and 19 on #225).
fn (mut c SoftChannel) rx_raw(timeout_ms int) ![]u8 {
	// NEGATIVE IS FOREVER, as the kernel channel and every bus have it. Computed as a deadline it
	// was a deadline in the past, and recv(-1) on the software channel returned timeout without
	// touching the bus (codex round 5 on #225).
	if timeout_ms < 0 {
		for {
			f := c.bus.recv(-1)!
			if f.id == c.rx_id && f.extended == c.ext && !f.rtr {
				return f.data.clone() // a received payload may be borrowed (transport.CanFrame)
			}
		}
	}
	deadline := time.ticks() + i64(timeout_ms)
	// ZERO IS ONE LOOK, as the kernel channel's poll(0) is: a queued frame is returned, an empty
	// queue is a timeout, and nothing waits (codex round 7 on #225).
	for {
		rem := deadline - time.ticks()
		// A zero timeout keeps looking past frames for OTHER ids until the bus reports its queue
		// empty — the bus's own zero-timeout read is one look, so a poll here ends when that
		// read times out, not after the first unrelated frame (codex round 12 on #225) — and
		// BOUNDED, because a bus busy with other ids without pause would otherwise keep a
		// non-blocking poll scanning forever (codex round 16 on #225).
		if rem <= 0 && (timeout_ms > 0 || c.scanned >= zero_poll_scan_frames) {
			return error('timeout')
		}
		c.scanned++
		f := c.bus.recv(int(if rem < 0 { i64(0) } else { rem }))!
		if f.id == c.rx_id && f.extended == c.ext && !f.rtr {
			return f.data.clone() // a received payload may be borrowed (transport.CanFrame)
		}
	}
	return error('timeout')
}

// orphan_note explains a silence the orphan-Flow-Control skip is responsible for. Read as a
// message an orphan FC surfaced as `unexpected PCI 0x31`; skipping it is right — this side never
// expects one — but it turned a diagnosable peer into a bare `timeout`, the one answer that says
// nothing about what is on the wire (#296). The original error is kept and the context added, so
// a real bus failure still reads as itself.
fn orphan_note(msg string, n int, pci u8) string {
	if n == 0 {
		return msg
	}
	return '${msg} — after ${n} orphan flow control frame(s), last PCI 0x${pci:02X}: the peer is still answering a transfer that ended'
}

// flush_rx drains rx-id frames until the bus has been quiet on that id, so a REUSED channel
// (a persistent UDS or script connection) starts clean rather than on a stale frame from an
// aborted transfer. Bounded: stops after a quiet window (no frame within flush_quiet_ms) or the
// frame cap.
//
// Its caller is the SEND side (#226): a segmented send that aborted leaves the peer's Flow
// Control frames in flight, and the next segmented send's own First Frame must not be answered
// by one of them. Not called before a Single Frame, and not needed after a successful recv —
// see fc_dirty for which exits end that window and why.
// A quiet window rather than a snapshot, because the last of a burst may not have arrived yet.
// The receive side does not call it — a flush there waits its window per frame and a slow peer
// renews it indefinitely past the deadline (codex round 5 on #225), so stale frames are dropped
// where the next reply is awaited instead. Before a send there is no deadline to overrun.
fn (mut c SoftChannel) flush_rx() {
	for _ in 0 .. flush_max_frames {
		c.rx_raw(flush_quiet_ms) or { return } // nothing more queued within the quiet window
	}
}
