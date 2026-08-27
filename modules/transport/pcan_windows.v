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
fn C.ct_pcan_read(u16, &u32, &u8, &u8, &u8) u32
fn C.ct_pcan_status(u16) u32
fn C.ct_pcan_condition(u16) int
fn C.ct_pcan_has_fd() int
fn C.ct_pcan_init_fd(u16, &char) u32
fn C.ct_pcan_write_fd(u16, u32, u8, u8, u8, &u8) u32
fn C.ct_pcan_read_fd(u16, &u32, &u8, &u8, &u8) u32

// PCAN message-type flags (mirror pcan_shim.h).
const pcan_msg_rtr = u8(0x01)
const pcan_msg_extended = u8(0x02)
const pcan_msg_status = u8(0x80)
const pcan_msg_fd = u8(0x04)
const pcan_msg_brs = u8(0x08)
const pcan_msg_esi = u8(0x10)

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
	// Opened for CAN-FD. THE CHANNEL DECIDES what it can carry, not the frame — a handle opened
	// classic cannot send an FD frame whatever the flags say, and an FD-opened one carries classic
	// frames too, so this is read on every send and every receive.
	fd bool
}

// open_pcan parses `pcan:<channel>[@<bitrate>]`, loads PCANBasic.dll and initializes
// the channel. Referenced only from open_windows.v, so the Linux build never sees it.
pub fn open_pcan(spec string) !&PcanBus {
	// BOTH RULES, from the file all three backends share: at most one bitrate, and that a whole
	// number. Validating only the second part let `@250000@500000` open at 250 kbit/s while the
	// project reported 500.
	// THE DATA RATE IN THE ADDRESS IS WHAT ASKS FOR FD, the same rule Kvaser and Vector follow:
	// `pcan:PCAN_USBBUS1@500000/2000000`. Nothing else can contradict it, because there is nothing
	// else to contradict — a channel is opened once, for one protocol.
	chan_part, bitrate, data_rate, want_fd := pcan_split_fd(spec, 500000) or {
		return error('PCAN: ${err}')
	}
	handle := pcan_handle(chan_part)!
	if C.ct_pcan_load() != 0 {
		return error('PCANBasic.dll not found — install the PEAK PCAN driver')
	}
	if want_fd {
		// A PRE-FD DRIVER IS A SENTENCE, NOT A CRASH. CAN_InitializeFD and friends simply are not
		// exported by an older PCANBasic, and the shim reports their absence rather than calling
		// through a null pointer.
		if C.ct_pcan_has_fd() == 0 {
			return error('PCAN: this PCANBasic.dll has no CAN_InitializeFD — CAN-FD needs a newer PEAK driver')
		}
		btr := pcan_fd_bitrate(bitrate, data_rate, pcan_default_sample_point) or {
			return error('PCAN: ${err.msg()}')
		}
		st := C.ct_pcan_init_fd(handle, btr.str)
		if st != 0 {
			return error('CAN_InitializeFD failed (0x${st:X}) for ${bitrate}/${data_rate} — adapter connected? bus terminated/powered?')
		}
		return &PcanBus{
			channel: handle
			fd:      true
		}
	}
	baud := pcan_baud(bitrate)!
	st := C.ct_pcan_init(handle, baud)
	if st != 0 {
		return error('CAN_Initialize failed (0x${st:X}) — adapter connected? bus terminated/powered?')
	}
	return &PcanBus{
		channel: handle
	}
}

// open_pcan_bus adapts open_pcan to the shared registry's factory signature. It takes the FULL
// interface string, because that is what the registry keeps as the wire's requested settings
// and compares a later opener against.
fn open_pcan_bus(iface string) !Bus {
	body := if iface.starts_with('pcan:') { iface['pcan:'.len..] } else { iface }
	return open_pcan(body)!
}

pub fn (mut b PcanBus) send(f CanFrame) ! {
	// THE SHARED SHAPE RULES FIRST (frame_rules.v). This path accepted `brs` on a classic frame
	// and simply never passed it to ct_pcan_write, reporting success — while wiretap kept the flag,
	// so the record claimed a bit-rate switch the wire never saw. Kvaser and Vector each refuse
	// that in their own words; PCAN had no such check at all, which is the per-backend duplication
	// this file was extracted to end (codex round 3 on #204). Length and FD stay below: what this
	// CHANNEL can carry is the backend's own question.
	if why := frame_shape_error(f) {
		return error('PCAN: ${why}')
	}
	mut mt := u8(0)
	if f.extended {
		mt |= pcan_msg_extended
	}
	// THE CHANNEL DECIDES WHICH CALL, NOT THE FRAME.
	//
	// An FD-initialised channel refuses CAN_Write outright — PCAN_ERROR_ILLOPERATION (0x8000000),
	// found on the bench when the classic legs of a cross-vendor run failed while every FD leg
	// passed. So a classic frame on an FD channel goes out through CAN_WriteFD too, with the FD
	// flag simply not set. The two calls are not interchangeable in either direction: a classic
	// channel has no CAN_WriteFD either.
	if b.fd {
		dlc := fd_dlc_for(f.data.len) or {
			return error('PCAN: ${f.data.len} bytes is not a payload size a DLC can express (id 0x${f.id:X}) — ${fd_lengths}')
		}
		if f.fd {
			mt |= pcan_msg_fd
			if f.brs {
				mt |= pcan_msg_brs
			}
			// ESI IS NOT SET HERE. It reports that the TRANSMITTING NODE was error-passive — the
			// controller's own condition, which it stamps itself — so a sender choosing it is a
			// sender lying about its state. Neither Kvaser's nor Vector's write takes it either,
			// and `CanFrame` says as much where the field is declared. Reachable from replay of a
			// recording, which carries flags verbatim (self-review).
		} else if f.data.len > 8 {
			// A classic frame is still a classic frame on an FD wire: eight bytes, whatever the
			// channel could otherwise carry. Refused rather than promoted, or the trace would
			// record a classic frame that went out as FD.
			return error('PCAN: ${f.data.len} bytes is not a classic CAN frame (id 0x${f.id:X}) — set fd on the frame, or send 8 bytes')
		}
		st := C.ct_pcan_write_fd(b.channel, f.id, mt, dlc, u8(f.data.len), f.data.data)
		match pcan_write_verdict(st) {
			.sent {}
			.busy { return busy_error('PCAN', f.id) }
			.failed { return error('CAN_WriteFD failed (0x${st:X})') }
		}
		return
	}
	if f.fd {
		// THE CHANNEL DECIDES. A handle opened classic cannot carry an FD frame whatever the flags
		// say — CAN_Write would put a classic frame on the wire and report success, which is the
		// silent truncation this backend has always refused. Say what to change, because the
		// answer is in the address.
		return error('PCAN: this channel is classic — name a data rate to open it for CAN-FD (pcan:${'<channel>'}@500000/2000000), id 0x${f.id:X}')
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
	match pcan_write_verdict(st) {
		.sent {}
		.busy { return busy_error('PCAN', f.id) }
		.failed { return error('CAN_Write failed (0x${st:X})') }
	}
}

pub fn (mut b PcanBus) recv(timeout_ms int) !CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		mut id := u32(0)
		mut mt := u8(0)
		mut ln := u8(0)
		// 64 BYTES ALWAYS, whichever call fills it: an FD-opened channel carries classic frames
		// too, and a classic-sized array here would be overrun by the first 64-byte frame.
		mut data := [64]u8{}
		// CAN_ReadFD ON AN FD CHANNEL, CAN_Read otherwise. They are different calls against
		// different structs, and the channel was opened for one of them.
		st := if b.fd {
			C.ct_pcan_read_fd(b.channel, &id, &mt, &ln, &data[0])
		} else {
			C.ct_pcan_read(b.channel, &id, &mt, &ln, &data[0])
		}
		// The status word decides, and the fault ladder in it is NOT a failure — see
		// pcan_read_verdict, which is where that rule lives and where a test can reach it.
		verdict := pcan_read_verdict(st)
		if verdict == .frame {
			if mt & pcan_msg_status != 0 {
				continue // PCAN status/error frame, not a data frame
			}
			// ON AN FD READ `ln` IS A DLC CODE, not a byte count — CAN_ReadFD fills DLC where
			// CAN_Read fills LEN. Treating the code as a length turns a 12-byte frame into 12
			// bytes of a 24-byte payload, silently.
			//
			// AND ONLY AN FD FRAME MAY USE THE HIGH CODES. An FD channel carries classic frames
			// too, and a classic DLC of 9..15 is legal and means EIGHT bytes — the codes above 8
			// mean 12..64 only for FD. Decoded through the FD table, such a frame was reported as
			// a 12-to-64-byte classic frame padded with the shim's zeros (self-review).
			is_fd := mt & pcan_msg_fd != 0
			n := if b.fd && is_fd {
				fd_len_for(ln)
			} else if int(ln) > 8 {
				8
			} else {
				int(ln)
			}
			mut out := []u8{len: n}
			for i in 0 .. n {
				out[i] = data[i]
			}
			return CanFrame{
				id:       id & 0x1FFF_FFFF
				extended: mt & pcan_msg_extended != 0
				// FROM THE FRAME, not from the channel: an FD-opened channel carries classic
				// frames too, and the trace has to tell them apart.
				fd:  mt & pcan_msg_fd != 0
				brs: mt & pcan_msg_brs != 0
				// A RECEIVED STATUS rather than a choice: the transmitter was error-passive.
				esi: mt & pcan_msg_esi != 0
				rtr:      mt & pcan_msg_rtr != 0
				data:     out
			}
		}
		if verdict == .failed {
			// Hex, because every PCANBasic status is written in hex in the vendor's header and
			// in ours: the bench read "CAN_Read failed (8)" and had to go looking for what 8
			// was. The health poll names the ladder in words; this names the raw word.
			return error('CAN_Read failed (0x${st:X})')
		}
		// .empty: receive queue empty — poll until the deadline.
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
