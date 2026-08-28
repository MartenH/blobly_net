module transport

import time

#include "socketcan_shim.h"

fn C.ct_can_open(&u8) int
fn C.ct_can_send(int, u32, &u8, u8, int, int, int) int
fn C.ct_can_recv(int, &u32, &u8, int, &u8) int
fn C.ct_can_close(int)
fn C.strerror(int) &char

// Stable SocketCAN id flag/mask constants (linux/can.h ABI).
const can_eff_flag = u32(0x8000_0000) // extended (29-bit) frame
const can_rtr_flag = u32(0x4000_0000) // remote transmission request
const can_sff_mask = u32(0x0000_07ff) // 11-bit id mask
const can_eff_mask = u32(0x1fff_ffff) // 29-bit id mask

// SocketCanBus is a raw SocketCAN backend bound to one interface.
pub struct SocketCanBus {
pub:
	iface string
mut:
	fd     int       = -1
	hstate BusHealth = .unknown // last kernel error-frame verdict; recv updates it
}

// open_socketcan binds a raw CAN socket to `iface` (e.g. 'vcan0').
pub fn open_socketcan(iface string) !&SocketCanBus {
	fd := C.ct_can_open(iface.str)
	if fd < 0 {
		return error('open ${iface}: ${cerr(-fd)}')
	}
	return &SocketCanBus{
		iface: iface
		fd:    fd
	}
}

pub fn (mut b SocketCanBus) send(frame CanFrame) ! {
	// A FRAME NO CONTROLLER COULD SEND is refused here as it is everywhere else. `esi` on a
	// classic frame arrived with the shared rules and this path never learned it, so the same
	// input was rejected by `inproc:`, `udp:`, PCAN and CANsub and accepted here — the flag
	// silently dropped, success reported, and the trace keeping a bit the wire never carried
	// (codex round 12 on #204).
	//
	// The IMPOSSIBLE rules only. What this backend does about a LENGTH is its own tier's business
	// and is unchanged — see frame_rules.v.
	if why := frame_send_refusal(frame) {
		return error('socketcan: ${why}')
	}
	mut cid := if frame.extended {
		(frame.id & can_eff_mask) | can_eff_flag
	} else {
		frame.id & can_sff_mask
	}
	// Padded HERE, by the one table in transport.v, so every backend puts the same bytes on the
	// wire. The C side keeps only a defensive clamp.
	payload := if frame.fd { fd_pad(frame.data) } else { frame.data }
	rc := C.ct_can_send(b.fd, cid, &u8(payload.data), u8(payload.len), if frame.fd {
		1
	} else {
		0
	}, if frame.brs { 1 } else { 0 }, if frame.esi { 1 } else { 0 })
	if rc < 0 {
		// EINVAL on an FD frame almost always means the interface is classic-only (the socket
		// declined CAN_RAW_FD_FRAMES at open). Say so, rather than leaving a bare errno for
		// somebody to decode on a bench.
		if frame.fd {
			return error('send FD frame on ${b.iface}: ${cerr(-rc)} (is the interface CAN-FD capable, and up?)')
		}
		return error('send: ${cerr(-rc)}')
	}
}

pub fn (mut b SocketCanBus) recv(timeout_ms int) !CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	mut buf := []u8{len: 64} // an FD frame is up to 64 bytes; a classic one fills the first 8
	mut polled := false
	for {
		mut raw_id := u32(0)
		mut fflags := u8(0)
		mut wait := timeout_ms
		if timeout_ms >= 0 {
			left := int(deadline - time.ticks())
			if left <= 0 {
				// Past the deadline the loop must EXIT, not downgrade to nonblocking polls:
				// draining a backlog of error frames at wait=0 overran the caller's budget by
				// the drain time, and an ISO-TP N_Cr timeout fed a late consecutive frame it
				// should have refused (self-review). One poll is still owed when nothing has
				// been tried yet — recv(0) is the drain loop's nonblocking probe.
				if polled {
					return error('timeout')
				}
				wait = 0
			} else {
				wait = left
			}
		}
		polled = true
		dlc := C.ct_can_recv(b.fd, &raw_id, &u8(buf.data), wait, &fflags)
		if dlc == -1 {
			return error('timeout')
		}
		if dlc <= -1000 {
			return error('recv on ${b.iface}: ${cerr(-(dlc + 1000))}') // the errno names the culprit
		}
		if dlc < 0 {
			return error('recv failed on ${b.iface}')
		}
		// A kernel ERROR frame (CAN_RAW_ERR_FILTER subscribed at open): the bus's health
		// talking, not traffic — fold it into the ladder, never surface it as data. The
		// unknown verdicts (bit error, ACK slot, …) leave the last ladder state alone.
		if is_socketcan_err(raw_id) {
			d1 := if dlc > 1 { buf[1] } else { u8(0) }
			h := socketcan_err_health(raw_id, d1)
			if h != .unknown {
				b.hstate = h
			}
			continue
		}
		// A DATA frame is proof of life: the documented bus-off recovery on Linux is
		// `ip link set canX down && up`, which resets the controller through close/open and
		// emits neither RESTARTED nor CRTL_ACTIVE — the latch would hold red on a bus that
		// is plainly carrying traffic again (self-review). Traffic clears it.
		if b.hstate == .bus_off {
			b.hstate = .ok
		}
		ext := (raw_id & can_eff_flag) != 0
		rtr := (raw_id & can_rtr_flag) != 0
		id := if ext { raw_id & can_eff_mask } else { raw_id & can_sff_mask }
		mut data := []u8{len: dlc}
		for i in 0 .. dlc {
			data[i] = buf[i]
		}
		return CanFrame{
			id:       id
			extended: ext
			rtr:      rtr
			fd:       fflags & 0x01 != 0
			brs:      fflags & 0x02 != 0
			esi:      fflags & 0x04 != 0
			data:     data
		}
	}
	// unreachable — every path exits by return above; V requires a terminal return after a
	// bare `for`
	return error('timeout')
}

// health reports the last kernel error-frame verdict — updated passively while recv runs
// (which is constantly: every open bus has its RX loop). .unknown until the kernel has said
// anything; a healthy bus emits no error frames, so unknown IS the healthy silence.
pub fn (mut b SocketCanBus) health() BusHealth {
	return b.hstate
}

// diagnostics: nothing this backend counts beyond frames and the health ladder (#213).
pub fn (mut b SocketCanBus) diagnostics() BusDiagnostics {
	return BusDiagnostics{}
}

// reconcile_silence — a SocketCAN interface's mode is chosen outside this app, by whoever ran
// `ip link set canX type can listen-only on`. There is nothing here that may revise it, and
// `vcan` has no transceiver at all.
pub fn (mut b SocketCanBus) reconcile_silence(want bool) ! {}

pub fn (mut b SocketCanBus) close() {
	if b.fd >= 0 {
		C.ct_can_close(b.fd)
		b.fd = -1
	}
}

fn cerr(errno int) string {
	return unsafe { cstring_to_vstring(C.strerror(errno)) }
}
