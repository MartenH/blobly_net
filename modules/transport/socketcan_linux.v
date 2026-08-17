module transport

#include "socketcan_shim.h"

fn C.ct_can_open(&u8) int
fn C.ct_can_send(int, u32, &u8, u8, int, int) int
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
	fd int = -1
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
	mut cid := if frame.extended {
		(frame.id & can_eff_mask) | can_eff_flag
	} else {
		frame.id & can_sff_mask
	}
	if frame.rtr {
		cid |= can_rtr_flag
	}
	// Padded HERE, by the one table in transport.v, so every backend puts the same bytes on the
	// wire. The C side keeps only a defensive clamp.
	payload := if frame.fd { fd_pad(frame.data) } else { frame.data }
	rc := C.ct_can_send(b.fd, cid, &u8(payload.data), u8(payload.len), if frame.fd {
		1
	} else {
		0
	}, if frame.brs { 1 } else { 0 })
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
	mut raw_id := u32(0)
	mut fflags := u8(0)
	mut buf := []u8{len: 64} // an FD frame is up to 64 bytes; a classic one fills the first 8
	dlc := C.ct_can_recv(b.fd, &raw_id, &u8(buf.data), timeout_ms, &fflags)
	if dlc == -1 {
		return error('timeout')
	}
	if dlc <= -1000 {
		return error('recv on ${b.iface}: ${cerr(-(dlc + 1000))}') // the errno names the culprit
	}
	if dlc < 0 {
		return error('recv failed on ${b.iface}')
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
		data:     data
	}
}

pub fn (mut b SocketCanBus) close() {
	if b.fd >= 0 {
		C.ct_can_close(b.fd)
		b.fd = -1
	}
}

fn cerr(errno int) string {
	return unsafe { cstring_to_vstring(C.strerror(errno)) }
}
