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
}

// open_software wraps a freshly opened bus on `iface` as an ISO-TP channel that
// sends on tx_id and receives on rx_id.
pub fn open_software(iface string, tx_id u32, rx_id u32, ext bool) !&SoftChannel {
	bus := transport.open(iface)!
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
	fc := c.rx_raw(1000)!
	if fc.len < 1 || (fc[0] & 0xF0) != 0x30 {
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
	first := c.rx_raw(timeout_ms)!
	if first.len < 1 {
		return error('ISO-TP: empty frame')
	}
	pci := first[0] & 0xF0
	if pci == 0x00 {
		len := int(first[0] & 0x0F)
		if 1 + len > first.len {
			return error('ISO-TP SF length ${len} exceeds frame')
		}
		return first[1..1 + len].clone()
	}
	if pci == 0x10 {
		if first.len < 2 {
			return error('ISO-TP FF too short')
		}
		total := (int(first[0] & 0x0F) << 8) | int(first[1])
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
			cf := c.rx_raw(timeout_ms)!
			if cf.len < 1 {
				continue // empty/padding read — ignore
			}
			if (cf[0] & 0xF0) != 0x20 {
				c.flush_rx() // discard the aborted transfer's tail so a reused channel resyncs
				return error('ISO-TP: expected Consecutive Frame, got PCI 0x${cf[0]:02X} mid-reassembly (a frame was lost)')
			}
			if (cf[0] & 0x0F) != sn {
				c.flush_rx()
				return error('ISO-TP: CF sequence gap — got SN ${cf[0] & 0x0F}, expected ${sn} (a frame was lost)')
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

fn (mut c SoftChannel) rx_raw(timeout_ms int) ![]u8 {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		rem := deadline - time.ticks()
		if rem <= 0 {
			return error('timeout')
		}
		f := c.bus.recv(int(rem))!
		if f.id == c.rx_id {
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
