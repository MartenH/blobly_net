// pcan_windows.v — PEAK PCAN-Basic backend (real CAN hardware on Windows),
// implementing the platform-agnostic `Bus` interface. Windows-only (the `_windows.v`
// suffix gates compilation). The vendor DLL (PCANBasic.dll, shipped with the free
// PEAK driver) is loaded at RUNTIME via pcan_shim.h — no SDK, no import lib.
//
// Interface string: `pcan:<channel>[@<arbitration>[/<data>]]`
//   channel     : PCAN_USBBUS1..8 | usb1..8 | 1..8 | a raw 0x51-style handle
//   arbitration : bits/s (default 500000)   e.g. pcan:PCAN_USBBUS1@250000
//   data        : bits/s, and NAMING IT IS WHAT ASKS FOR CAN-FD — the same rule Kvaser and
//                 Vector follow, because a channel is opened once, for one protocol, and
//                 nothing else can then contradict it.
//                 e.g. pcan:PCAN_USBBUS1@500000/2000000
//
// CLASSIC AND FD ARE DIFFERENT CALLS, and the difference reaches further than opening: an
// FD-initialised channel REFUSES CAN_Write outright (PCAN_ERROR_ILLOPERATION), so every send on
// such a channel goes through CAN_WriteFD, classic frames included, with the FD flag clear. Found
// on the bench, where every FD leg passed and every classic one failed.
//
// The address rules and the FD bit-timing solver are in pcan_names.v, not here: a `_windows.v`
// file compiles only where CI runs nothing, and PCANBasic takes a bit-rate STRING of register
// values rather than a rate constant, so that arithmetic is exactly what a test should hold.
//
// Hardware-verified on a PCAN-USB Pro FD — classic, and CAN-FD cross-vendor against a Kvaser
// USBcan Pro 5xHS, 18/18 in both directions at 1/2/4/8 Mbit/s. See docs/windows_can_hardware.md
// for the bench record and what "verified" means there.
module transport

import sync.stdatomic
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
fn C.ct_pcan_set_silent(u16, int) u32

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
	// The wire this handle is, so the silence policy can be asked about it — see ensure_silence.
	iface string
	// Opened for CAN-FD. THE CHANNEL DECIDES what it can carry, not the frame — a handle opened
	// classic cannot send an FD frame whatever the flags say, and an FD-opened one carries classic
	// frames too, so this is read on every send and every receive.
	fd bool
	// Receive overruns seen on this channel: frames the driver dropped because nobody read fast
	// enough. COUNTED, not silent, and not fatal — see pcan_read_verdict; diagnostics() is how it
	// reaches the Buses row (#213).
	overruns u64
}

// open_pcan parses `pcan:<channel>[@<bitrate>]`, loads PCANBasic.dll and initializes
// the channel. Referenced only from open_windows.v, so the Linux build never sees it.
pub fn open_pcan(spec string, iface string) !&PcanBus {
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
	// THE MODE IS CHOSEN BEFORE THE CHANNEL JOINS THE BUS, and it is a safety property rather than
	// a tidiness one. CAN_Initialize brings the channel up; a listen-only parameter applied after
	// it leaves a window in which a row marked listen-only is an ACKNOWLEDGING node on somebody's
	// live vehicle, at a bitrate that is a default nobody has confirmed — the very thing a row
	// defaulting to listen-only exists to prevent (codex round 1 on #219).
	//
	// PCANBasic accepts PCAN_LISTEN_ONLY on a channel that is not yet initialized and CARRIES IT
	// THROUGH the initialization: measured on a PCAN-USB Pro FD, where reading the parameter back
	// after CAN_Initialize returns the value set before it. That is what makes this order possible
	// at all, and it is why it was measured rather than assumed — a status of PCAN_ERROR_OK on an
	// uninitialized channel would look identical if the value were being accepted and discarded.
	//
	// SET IN BOTH DIRECTIONS, not only when silence is wanted: the mode belongs to the channel and
	// another process may have left it silent, so `false` is as much an instruction as `true`.
	//
	// AND A REFUSAL FAILS THE OPEN when silence was asked for. Everything above is a promise the
	// operator ticked a box for; handing back a bus that acknowledges while the UI says it does not
	// is the one outcome worse than not opening at all.
	silent := is_listen_only(iface)
	sst := C.ct_pcan_set_silent(handle, if silent { 1 } else { 0 })
	if sst != 0 && silent {
		return error('PCAN: the channel would not be set listen-only (CAN_SetValue 0x${sst:X}) — this wire is marked never-transmit and the controller would still acknowledge, so it is not opened')
	}
	// A REFUSED *NORMAL* SET IS NOT A SUCCESS EITHER, and the wire must be left UNKNOWN rather
	// than recorded. Opening normal is what repairs a channel a previous run left silent — the
	// whole reason the first write is unconditional — so if that write is the one that fails,
	// recording `false` claims the repair happened and suppresses every later attempt. The channel
	// then cannot transmit and nothing retries (codex round 3 on #219).
	//
	// Not fatal, unlike the silent direction: a controller that will not leave listen-only is a
	// wire that transmits nothing, which `send` reports and the Buses panel shows, where refusing
	// to open would also take away the receiving that still works.
	applied := sst == 0
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
		if applied {
			note_silence_applied(iface, silent)
		}
		return &PcanBus{
			channel: handle
			iface:   iface
			fd:      true
		}
	}
	baud := pcan_baud(bitrate)!
	st := C.ct_pcan_init(handle, baud)
	if st != 0 {
		return error('CAN_Initialize failed (0x${st:X}) — adapter connected? bus terminated/powered?')
	}
	if applied {
		note_silence_applied(iface, silent)
	}
	return &PcanBus{
		channel: handle
		iface:   iface
	}
}

// reconcile_silence makes the CONTROLLER match this wire's silence policy — the half of
// listen-only that software refusal cannot do, because the ACK is the transceiver's. listen.v
// carries the whole reasoning; silence.v carries why the record is keyed by WIRE.
//
// MID-RUN ONLY, like Kvaser's: `open_pcan` sets the parameter BEFORE CAN_Initialize, so a channel
// is never on the bus in the wrong mode even for an instant.
//
// PCANBasic spells it as a channel PARAMETER (`CAN_SetValue` with `PCAN_LISTEN_ONLY`), which is
// taken at any time and needs no bus bounce, unlike canlib.
pub fn (mut b PcanBus) reconcile_silence(want bool) ! {
	ch := b.channel
	apply_silence(b.iface, want, fn [ch] (silent bool) int {
		return int(C.ct_pcan_set_silent(ch, if silent { 1 } else { 0 }))
	})!
}

// open_pcan_bus adapts open_pcan to the shared registry's factory signature. It takes the FULL
// interface string, because that is what the registry keeps as the wire's requested settings
// and compares a later opener against.
fn open_pcan_bus(iface string) !Bus {
	body := if iface.starts_with('pcan:') { iface['pcan:'.len..] } else { iface }
	return open_pcan(body, iface)!
}

pub fn (mut b PcanBus) send(f CanFrame) ! {
	// NO RECONCILE HERE. `SilentBus.send` has already done it, with the ONE policy snapshot it also
	// refuses on — and doing it again here meant reading the policy a SECOND time. A mark set
	// between the two reads then reconciled the controller to silent and let this send continue
	// into the driver anyway, because only the wrapper decides whether to refuse: the first frame
	// after the toggle still went out (codex round 8 on #219).
	//
	// That is the same two-reads defect for the third time — #202 r3 inside the wrapper, round 3 of
	// this PR between wrapper and backend, and now below the backend. The cure is not another
	// parameter to thread: every bus this app hands out comes from `open`, which always wraps, so
	// the wrapper's reconcile is guaranteed to have run and this one could only ever disagree with
	// it. The RECEIVE path keeps its own reconcile — there is no second read to disagree with
	// there, and it is what retries a refusal.
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
	// Best effort on the read side: a receive that fails takes the wire's reader down with it. NOT
	// discarded, though — `apply_silence` records the refusal against the wire and the Buses panel
	// reads it, because a passive listener never calls send and this `or {}` was otherwise the end
	// of the story on a receive-only wire (codex round 3 on #219).
	b.reconcile_silence(is_listen_only(b.iface)) or {}
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
				esi:  mt & pcan_msg_esi != 0
				rtr:  mt & pcan_msg_rtr != 0
				data: out
			}
		}
		if verdict == .overrun {
			// Frames were lost; the channel was not. Keep reading — there may be a frame behind
			// the status right now, and returning an error here is what killed the wire: through
			// the shared hub a fatal read uninitialises the channel under every handle (#221).
			stdatomic.add_u64(&b.overruns, 1)
			continue
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
	// AND FORGET WHAT THE WIRE WAS RECORDED AS, because CAN_Uninitialize RESETS the controller's
	// mode. A record that outlives the state it describes is worse than none: the next open would
	// find "already listen-only", skip the write, and hand back an acknowledging channel for a row
	// that is still marked (codex round 1 on #219).
	//
	// Reached only when the LAST holder of this wire lets go — `pcan:` opens go through the
	// refcounted registry in shared.v, which calls this on the final release.
	//
	// Kvaser deliberately does NOT do this: `canClose` leaves the driver mode in place, so there
	// the record is still true after the handle is gone.
	//
	// BELT AND BRACES SINCE THE OPEN PATH WRITES UNCONDITIONALLY, and worth saying so rather than
	// letting the comment above imply a test proves it. `open_pcan` sets the parameter before every
	// CAN_Initialize and calls note_silence_applied afterwards, so a stale record is overwritten by
	// the next open whether or not this line runs — and `cmd/silentcheck` phase 4 cannot tell the
	// difference, because clearing the whole table is exactly how it simulates a fresh process. The
	// rule this keeps is still worth keeping: a record must not outlive the state it describes.
	// What holds it is silence_test.v, at the level where the effect is actually observable.
	forget_wire_silence(b.iface)
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

// diagnostics: the receive overruns pcan_read_verdict counts -- frames the driver dropped because
// nobody read fast enough (#213).
pub fn (mut b PcanBus) diagnostics() BusDiagnostics {
	// Atomic: counted on the hub's reader thread, read from the GUI's RX loop.
	return BusDiagnostics{
		dropped: stdatomic.load_u64(&b.overruns)
	}
}
