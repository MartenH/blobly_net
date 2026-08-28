// software.v — a pure-V ISO-TP (ISO 15765-2) state machine over any transport.Bus.
//
// Unlike kernel_linux.v (which offloads segmentation to the kernel CAN_ISOTP
// socket), this implements SF/FF/CF/FC in software, so it runs on ANY bus backend
// — the in-process simulation bus, the UDP software bus, or (later) a Windows
// vendor driver that has no kernel ISO-TP. Cross-platform (unsuffixed file). It
// implements the same `Channel` interface, so UDS rides on it unchanged.
//
// Scope: classic addressing, single + multi-frame, 8-byte padded frames, flow
// control sent/honoured minimally (block size + STmin ignored — fine in-process).
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
		return c.tx(sf)
	}
	// First Frame: PCI 0x1<len_hi><len_lo> + first 6 bytes.
	mut ff := [u8(0x10 | u8((data.len >> 8) & 0x0F)), u8(data.len & 0xFF)]
	ff << data[..6]
	c.tx(ff)!
	// Await Flow Control (0x3x). We ignore block size / STmin and send all CFs.
	// STALE CONSECUTIVE FRAMES ARE SKIPPED HERE TOO: a transfer this channel abandoned on its
	// deadline can still be arriving when the caller sends the next request, and the first frame
	// met while waiting for Flow Control was one of them — "expected Flow Control" for a peer
	// that had not answered yet (codex round 11 on #225). Bounded by the same one second.
	fc_deadline := time.ticks() + 1000
	mut fc := []u8{}
	for {
		rem := int(fc_deadline - time.ticks())
		if rem <= 0 {
			return error('timeout')
		}
		fc = c.rx_raw(rem)!
		if fc.len >= 1 && (fc[0] & 0xF0) == 0x20 {
			continue
		}
		break
	}
	if fc.len < 1 {
		// Split from the PCI check below: it formatted fc[0] for an EMPTY frame, an
		// out-of-bounds panic where an ISO-TP error was owed (codex round 3 on #225).
		return error('ISO-TP: expected Flow Control, got an empty frame')
	}
	if (fc[0] & 0xF0) != 0x30 {
		return error('ISO-TP: expected Flow Control, got 0x${fc[0]:02X}')
	}
	mut sn := u8(1)
	mut off := 6
	for off < data.len {
		n := if data.len - off > 7 { 7 } else { data.len - off }
		mut cf := [u8(0x20 | (sn & 0x0F))]
		cf << data[off..off + n]
		c.tx(cf)!
		sn = (sn + 1) & 0x0F
		off += n
	}
}

// recv reassembles one ISO-TP PDU (SF directly; FF → send FC → collect CFs).
pub fn (mut c SoftChannel) recv(timeout_ms int) ![]u8 {
	// ONE DEADLINE FOR THE WHOLE PDU. Each Consecutive Frame used to get the full timeout afresh,
	// so a peer stalling just under it between frames made request(..., 2000) wait many times
	// two seconds, where the kernel channel bounds the reassembled PDU (codex round 3 on #225).
	// Negative is "forever", as everywhere else.
	deadline := time.ticks() + i64(timeout_ms)
	c.scanned = 0
	mut first := []u8{}
	for {
		mut rem := timeout_ms
		if timeout_ms >= 0 {
			rem = int(deadline - time.ticks())
			// A zero timeout keeps polling past stale Consecutive Frames as well: the poll ends
			// when rx_raw reports the bus empty, not after the first frame it had to drop (codex
			// round 13 on #225). A positive timeout expires by the clock.
			if rem <= 0 && timeout_ms > 0 {
				return error('timeout')
			}
			if rem < 0 {
				rem = 0
			}
		}
		first = c.rx_raw(rem)!
		if first.len < 1 {
			return error('ISO-TP: empty frame')
		}
		// A CONSECUTIVE FRAME WITH NO TRANSFER IN PROGRESS IS A STALE TAIL, not a message: the
		// rest of a transfer this channel abandoned on its deadline, still arriving from a peer
		// that did not know. A flush at abort time cannot catch frames that have not arrived
		// yet, so they are dropped HERE, where the next reply is awaited (codex round 4 on
		// #225; the first cut flushed and the test proved it insufficient).
		if (first[0] & 0xF0) == 0x20 {
			continue
		}
		break
	}
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
				return f.data
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
			return f.data
		}
	}
	return error('timeout')
}

// flush_rx drains any rx-id frames still queued after a failed reassembly, so a REUSED channel
// (e.g. a persistent UDS/script connection) starts the next recv() clean on the next message's
// First Frame rather than a stale Consecutive Frame left over from the aborted transfer — which
// would otherwise re-desync the channel with the same "unexpected PCI" the SN check just caught.
// Bounded: stops after a quiet window (no frame within flush_quiet_ms) or the frame cap.
fn (mut c SoftChannel) flush_rx() {
	for _ in 0 .. flush_max_frames {
		c.rx_raw(flush_quiet_ms) or { return } // nothing more queued within the quiet window
	}
}
