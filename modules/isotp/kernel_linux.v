// kernel_linux.v — the Linux/WSL ISO-TP backend, built on the kernel's
// CAN_ISOTP socket (the kernel handles SF/FF/CF framing + flow control). Only
// compiled on Linux (the `_linux.v` suffix gates it), so the linux/can headers
// never reach a Windows build. Implements the platform-agnostic isotp.Channel.
module isotp

#include "isotp_shim.h"

fn C.ct_isotp_open(&u8, u32, u32) int
fn C.ct_isotp_send(int, &u8, int) int
fn C.ct_isotp_recv(int, &u8, int, int) int
fn C.ct_isotp_close(int)
fn C.strerror(int) &char

const can_eff_flag = u32(0x8000_0000) // extended (29-bit) frame
const can_eff_mask = u32(0x1fff_ffff)
const can_sff_mask = u32(0x0000_07ff)

// KernelChannel is one kernel ISO-TP socket bound to a (tx,rx) id pair.
struct KernelChannel {
pub:
	iface string
	tx_id u32
	rx_id u32
mut:
	fd int = -1
}

// open_kernel binds a kernel ISO-TP socket on `iface`, transmitting on `tx_id`
// and receiving on `rx_id`. Set `extended` for 29-bit identifiers. Returns the
// platform-agnostic Channel interface. Reached through isotp.open on Linux;
// named, so a caller can ask for the kernel specifically.
pub fn open_kernel(iface string, tx_id u32, rx_id u32, extended bool) !Channel {
	check_ids(iface, tx_id, rx_id, extended)!
	tx := encode_id(tx_id, extended)
	rx := encode_id(rx_id, extended)
	fd := C.ct_isotp_open(iface.str, rx, tx)
	if fd < 0 {
		return error('isotp open ${iface} (tx=0x${tx_id:X} rx=0x${rx_id:X}): ${cerr(-fd)}')
	}
	return &KernelChannel{
		iface: iface
		tx_id: tx_id
		rx_id: rx_id
		fd:    fd
	}
}

fn (mut c KernelChannel) send(data []u8) ! {
	if data.len == 0 {
		return error('isotp send: empty pdu')
	}
	if data.len > max_pdu {
		return error('isotp send: pdu ${data.len} > ${max_pdu} bytes')
	}
	rc := C.ct_isotp_send(c.fd, &u8(data.data), data.len)
	if rc < 0 {
		return error('isotp send: ${cerr(-rc)}')
	}
}

fn (mut c KernelChannel) recv(timeout_ms int) ![]u8 {
	mut buf := []u8{len: max_pdu}
	n := C.ct_isotp_recv(c.fd, &u8(buf.data), buf.len, timeout_ms)
	if n == -1 {
		return error('timeout')
	}
	if n < 0 {
		return error('isotp recv failed on ${c.iface}')
	}
	return buf[..n].clone()
}

fn (mut c KernelChannel) close() {
	if c.fd >= 0 {
		C.ct_isotp_close(c.fd)
		c.fd = -1
	}
}

fn encode_id(id u32, extended bool) u32 {
	return if extended { (id & can_eff_mask) | can_eff_flag } else { id & can_sff_mask }
}

fn cerr(errno int) string {
	return unsafe { cstring_to_vstring(C.strerror(errno)) }
}
