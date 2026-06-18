// pcan_windows.v — PEAK PCAN-Basic backend (real CAN hardware on Windows),
// implementing the platform-agnostic `Bus` interface. Windows-only (the `_windows.v`
// suffix gates compilation). The vendor DLL (PCANBasic.dll, shipped with the free
// PEAK driver) is loaded at RUNTIME via pcan_shim.h — no SDK, no import lib.
//
// Interface string: `pcan:<channel>[@<bitrate>]`
//   channel : PCAN_USBBUS1..8 | usb1..8 | 1..8 | a raw 0x51-style handle
//   bitrate : bits/s (default 500000)  e.g. pcan:PCAN_USBBUS1@250000
//
// NOTE: written from the documented PCAN-Basic ABI; NOT yet verified against
// hardware (no adapter/driver available on the dev box). Compile-checked via the
// Windows CI. See docs/windows_can_hardware.md for the verification plan.
module transport

import time

#include "pcan_shim.h"

fn C.ct_pcan_load() int
fn C.ct_pcan_init(u16, u16) u32
fn C.ct_pcan_uninit(u16) u32
fn C.ct_pcan_write(u16, u32, u8, u8, &u8) u32
fn C.ct_pcan_read(u16, &u32, &u8, &u8, &u8) int

// PCAN message-type flags (mirror pcan_shim.h).
const pcan_msg_rtr = u8(0x01)
const pcan_msg_extended = u8(0x02)
const pcan_msg_status = u8(0x80)

// PcanBus is one initialized PCAN channel.
pub struct PcanBus {
mut:
	channel u16
}

// open_pcan parses `pcan:<channel>[@<bitrate>]`, loads PCANBasic.dll and initializes
// the channel. Referenced only from open_windows.v, so the Linux build never sees it.
pub fn open_pcan(spec string) !&PcanBus {
	parts := spec.split('@')
	handle := pcan_handle(parts[0])!
	bitrate := if parts.len > 1 { parts[1].int() } else { 500000 }
	baud := pcan_baud(bitrate)!
	if C.ct_pcan_load() != 0 {
		return error('PCANBasic.dll not found — install the PEAK PCAN driver')
	}
	st := C.ct_pcan_init(handle, baud)
	if st != 0 {
		return error('CAN_Initialize failed (0x${st:X}) — adapter connected? bus terminated/powered?')
	}
	return &PcanBus{
		channel: handle
	}
}

pub fn (mut b PcanBus) send(f CanFrame) ! {
	mut mt := u8(0)
	if f.extended {
		mt |= pcan_msg_extended
	}
	if f.rtr {
		mt |= pcan_msg_rtr
	}
	mut n := f.data.len
	if n > 8 {
		n = 8
	}
	st := C.ct_pcan_write(b.channel, f.id, mt, u8(n), f.data.data)
	if st != 0 {
		return error('CAN_Write failed (0x${st:X})')
	}
}

pub fn (mut b PcanBus) recv(timeout_ms int) !CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		mut id := u32(0)
		mut mt := u8(0)
		mut ln := u8(0)
		mut data := [8]u8{}
		r := C.ct_pcan_read(b.channel, &id, &mt, &ln, &data[0])
		if r == 0 {
			if mt & pcan_msg_status != 0 {
				continue // PCAN status/error frame, not a data frame
			}
			mut out := []u8{len: int(ln)}
			for i in 0 .. int(ln) {
				out[i] = data[i]
			}
			return CanFrame{
				id:       id & 0x1FFF_FFFF
				extended: mt & pcan_msg_extended != 0
				rtr:      mt & pcan_msg_rtr != 0
				data:     out
			}
		}
		if r < 0 {
			return error('CAN_Read failed (${-r})')
		}
		// r == 1: receive queue empty — poll until the deadline.
		if timeout_ms >= 0 && time.ticks() >= deadline {
			return error('timeout')
		}
		time.sleep(time.millisecond)
	}
	return error('timeout')
}

pub fn (mut b PcanBus) close() {
	C.ct_pcan_uninit(b.channel)
}

// pcan_handle maps a channel spec to a PCANBasic channel handle. USB handles are
// 0x51..0x58 (PCAN_USBBUS1..8) — the common case for the owner's adapters.
fn pcan_handle(s string) !u16 {
	t := s.trim_space()
	low := t.to_lower()
	if low.starts_with('0x') {
		return u16(t.all_after('0x').parse_uint(16, 16) or { return error('bad PCAN handle "${t}"') })
	}
	mut n := -1
	if low.starts_with('pcan_usbbus') {
		n = low.all_after('pcan_usbbus').int()
	} else if low.starts_with('usb') {
		n = low.all_after('usb').int()
	} else if t[0].is_digit() {
		n = t.int()
	}
	if n >= 1 && n <= 8 {
		return u16(0x50 + n) // PCAN_USBBUS1 == 0x51
	}
	return error('unknown PCAN channel "${t}" (use PCAN_USBBUS1..8, usb1.., 1.., or 0x51)')
}

// pcan_baud maps a bit rate to the PCANBasic BTR0BTR1 baudrate code.
fn pcan_baud(bitrate int) !u16 {
	return match bitrate {
		1000000 { u16(0x0014) }
		800000 { u16(0x0016) }
		500000 { u16(0x001C) }
		250000 { u16(0x011C) }
		125000 { u16(0x031C) }
		100000 { u16(0x432F) }
		50000 { u16(0x472F) }
		20000 { u16(0x532F) }
		10000 { u16(0x672F) }
		else { error('unsupported PCAN bitrate ${bitrate} (use 10k/20k/50k/100k/125k/250k/500k/800k/1M)') }
	}
}
