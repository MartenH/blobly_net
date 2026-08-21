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
fn C.ct_pcan_status(u16) u32
fn C.ct_pcan_condition(u16) int

// PCAN message-type flags (mirror pcan_shim.h).
const pcan_msg_rtr = u8(0x01)
const pcan_msg_extended = u8(0x02)
const pcan_msg_status = u8(0x80)

// pcan_list probes the fixed PCAN USB channel handles (PCAN_USBBUS1..8 = 0x51..0x58)
// for discovery. Returns [] when PCANBasic.dll is absent or nothing is attached.
fn pcan_list() []Iface {
	mut out := []Iface{}
	for n in 1 .. 9 {
		cond := C.ct_pcan_condition(u16(0x50 + n)) // PCAN_USBBUS1 = 0x51
		if cond > 0 { // 0x01 available | 0x04 occupied
			out << Iface{
				name:    'PCAN_USBBUS${n}'
				iface:   'pcan:PCAN_USBBUS${n}'
				kind:    'can'
				virtual: false
			}
		}
	}
	return out
}

// PcanBus is one initialized PCAN channel.
pub struct PcanBus {
mut:
	channel u16
}

// open_pcan parses `pcan:<channel>[@<bitrate>]`, loads PCANBasic.dll and initializes
// the channel. Referenced only from open_windows.v, so the Linux build never sees it.
pub fn open_pcan(spec string) !&PcanBus {
	// BOTH RULES, from the file all three backends share: at most one bitrate, and that a whole
	// number. Validating only the second part let `@250000@500000` open at 250 kbit/s while the
	// project reported 500.
	chan_part, bitrate := vendor_split_rate(spec, 500000) or { return error('PCAN: ${err}') }
	handle := pcan_handle(chan_part)!
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
	// CAN-FD is not implemented on this backend: the vendor call below writes a classic frame,
	// so an FD frame would go out truncated and report success. Refuse — a bench that silently
	// changes what it transmits is worse than one that stops.
	if f.fd {
		return error('PCAN: CAN-FD frames are not supported by this backend yet (id 0x${f.id:X}, ${f.data.len} bytes)')
	}
	mut mt := u8(0)
	if f.extended {
		mt |= pcan_msg_extended
	}
	if f.rtr {
		mt |= pcan_msg_rtr
	}
	// REFUSED, not truncated — the same rule this backend already applies to an FD frame, and
	// for the same reason. A vendor interface is not clamps_to_classic(), so wire_frame() gives
	// the trace the frame AS ASKED: truncating here records nine bytes against eight on the
	// wire, and the echo can never match its own record.
	if f.data.len > 8 {
		return error('PCAN: ${f.data.len} bytes is not a classic CAN frame (id 0x${f.id:X}) — 8 is the maximum without FD')
	}
	n := f.data.len
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

// health asks CAN_GetStatus for the controller's fault ladder. 0xFFFFFFFF means the loaded
// DLL predates the symbol — reported as unknown, never as a state; the decode itself lives
// in health.v where a test pins it to PCANBasic.h's constants.
pub fn (mut b PcanBus) health() BusHealth {
	st := C.ct_pcan_status(b.channel)
	if st == 0xFFFF_FFFF {
		return .unknown
	}
	return pcan_status_health(st)
}

// pcan_handle maps a channel spec to a PCANBasic channel handle. USB handles are
// 0x51..0x58 (PCAN_USBBUS1..8) — the common case for the owner's adapters.

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
