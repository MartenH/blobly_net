// kvaser_windows.v — Kvaser CANlib backend (real CAN hardware on Windows),
// implementing the platform-agnostic `Bus` interface. Windows-only (`_windows.v`
// suffix gates compilation). canlib32.dll (shipped with the free Kvaser drivers) is
// loaded at RUNTIME via kvaser_shim.h — no SDK, no import lib.
//
// Interface string: `kvaser:<channel>[@<arb>[/<data>]]`
//   channel : Kvaser channel number (0,1,…). Virtual channels (available once the
//             Kvaser drivers are installed, NO hardware needed) appear as channel
//             numbers too — find them in the Kvaser Device Guide.
//   arb     : arbitration bits/s (default 500000)   e.g. kvaser:0@250000
//   data    : CAN-FD DATA-phase bits/s. Naming it IS the FD flag -- there is no separate
//             `,fd`, so no address can claim FD while naming one rate. 500k/1M/2M/4M/8M.
//             e.g. kvaser:0@500000/2000000  (64-byte payloads, bit-rate switched)
//
// Because Kvaser offers software virtual channels, this backend can be verified
// end-to-end with no physical adapter (open two handles on the same virtual channel
// number, send on one, recv on the other). See docs/windows_can_hardware.md.
//
// Bench-verified on a Kvaser USBcan Pro 5xHS, connector CH1 to CH2 over real transceivers with
// two 120 ohm terminators: classic CAN, and CAN-FD with BRS at data rates 500k, 1M, 2M, 4M and
// 8M, at payload lengths 8, 12, 16, 24, 32, 48 and 64 bytes, with zero error frames and both
// controllers error-active throughout. `cmd/kvasercheck --ladder` is that run. The remaining FD
// lengths (0..7 and 20) are exercised only by the length rule in kvaser_fd_test.v, not on copper.
// See docs/windows_can_hardware.md.
module transport

#include "kvaser_shim.h"

fn C.ct_kvaser_load() int
fn C.ct_kvaser_open(int, int) int
fn C.ct_kvaser_open_fd(int, int, int) int
fn C.ct_kvaser_write_fd(int, u32, u8, &u8, int, int) int
fn C.ct_kvaser_has_fd() int
fn C.ct_kvaser_write(int, u32, u8, &u8, int, int) int
fn C.ct_kvaser_read(int, &u32, &u8, &u8, &int, &int, &int, &int, u32) int
fn C.ct_kvaser_close(int)
fn C.ct_kvaser_status(int, &u32) int
fn C.ct_kvaser_count() int
fn C.ct_kvaser_descr(int, &char, int) int
fn C.ct_kvaser_is_virtual(int) int

// KvaserBus is one open + bus-on CANlib channel handle.
pub struct KvaserBus {
mut:
	handle int
	// The mode this handle was OPENED in. A channel opened classic cannot carry an FD frame
	// however the frame is flagged, so send() has to know -- and a channel opened FD still
	// carries classic frames, which is why recv reads the flags per frame rather than assuming.
	fd bool
}

// open_kvaser parses `kvaser:<channel>[@<arb>[/<data>]]`, loads canlib32.dll, opens the channel
// (classic, or CAN-FD when the address names a data rate) and goes bus-on.
// The address rules live in kvaser_names.v, where a CI runner with no adapter can check them.
// Referenced only from open_windows.v.
pub fn open_kvaser(spec string) !&KvaserBus {
	s := kvaser_spec(spec)!
	// The arbitration code comes from a DIFFERENT family depending on the mode -- see
	// kvaser_fd_arb_code for why an FD channel must not take the classic constant.
	arb_code := if s.fd { kvaser_fd_arb_code(s.bitrate)! } else { kvaser_bitrate_code(s.bitrate)! }
	if C.ct_kvaser_load() != 0 {
		return error('canlib32.dll not found — install the Kvaser drivers')
	}
	if !s.fd {
		hnd := C.ct_kvaser_open(s.channel, arb_code)
		if hnd < 0 {
			return error('Kvaser: could not open channel ${s.channel} — ${kvaser_open_refusal(hnd,
				s.channel, false)}')
		}
		return &KvaserBus{
			handle: hnd
		}
	}
	// ASKED OF THE LIBRARY, not assumed from its version. canSetBusParamsFd is absent from a
	// canlib old enough to predate FD, and calling through a null pointer is a crash where a
	// sentence would do.
	if C.ct_kvaser_has_fd() == 0 {
		return error('Kvaser: this canlib32.dll has no CAN-FD API (canSetBusParamsFd missing) — update the Kvaser drivers')
	}
	data_code := kvaser_fd_data_code(s.data_bitrate)!
	hnd := C.ct_kvaser_open_fd(s.channel, arb_code, data_code)
	if hnd < 0 {
		return error('Kvaser: could not open channel ${s.channel} for CAN-FD at ${s.bitrate}/${s.data_bitrate} — ${kvaser_open_refusal(hnd,
			s.channel, true)}')
	}
	return &KvaserBus{
		handle: hnd
		fd:     true
	}
}

pub fn (mut b KvaserBus) send(f CanFrame) ! {
	// BRS WITHOUT FD IS NOT A FRAME. Bit-rate switching is a property of an FD frame's data
	// phase; a classic frame has no second phase to switch into. Left through, it goes out
	// classic and reports success while the trace records a switch that never happened — the
	// same silent disagreement between record and wire that the FD refusal below exists to
	// prevent. Vector refuses it for the same reason.
	// RTR HAS NO PLACE IN CAN-FD. The standard removed it: an FD frame's control field carries
	// FDF where RTR sat, so a remote FD request does not exist. Left through, the shim built an
	// ordinary FDF data frame and send() reported success for a message nobody asked for -- the
	// same silent substitution the refusals below exist to prevent. Vector refuses the pair too.
	if f.rtr && f.fd {
		return error('Kvaser: rtr with fd (id 0x${f.id:X}) — CAN-FD has no remote frames; the bit RTR used to occupy carries FDF')
	}
	if f.brs && !f.fd {
		return error('Kvaser: brs without fd (id 0x${f.id:X}) — bit-rate switching belongs to a CAN-FD frame\'s data phase, and a classic frame has none')
	}
	if f.fd {
		// THE CHANNEL DECIDES, not the frame. A handle opened classic cannot carry an FD frame
		// whatever the flags say -- canWrite would put a classic frame on the wire and report
		// success, which is the silent truncation this backend has always refused. Say what to
		// change, because the answer is in the address.
		if !b.fd {
			return error('Kvaser: this channel is classic — name a data rate to open it for CAN-FD (kvaser:${'N'}@500000/2000000), id 0x${f.id:X}')
		}
		if f.data.len !in fd_lengths {
			return error('Kvaser: ${f.data.len} bytes is not a CAN-FD length (id 0x${f.id:X}) — 0..8, 12, 16, 20, 24, 32, 48 or 64')
		}
		ext := if f.extended { 1 } else { 0 }
		brs := if f.brs { 1 } else { 0 }
		st := C.ct_kvaser_write_fd(b.handle, f.id, u8(f.data.len), f.data.data, ext, brs)
		if st < 0 {
			return error('canWrite (FD) failed (canStatus ${st})')
		}
		return
	}
	// REFUSED, not truncated — a vendor interface is not clamps_to_classic(), so wire_frame()
	// gives the trace the frame AS ASKED: truncating here records nine bytes against eight on the
	// wire, and the echo can never match its own record.
	if f.data.len > 8 {
		return error('Kvaser: ${f.data.len} bytes is not a classic CAN frame (id 0x${f.id:X}) — 8 is the maximum without FD')
	}
	n := f.data.len
	ext := if f.extended { 1 } else { 0 }
	rtr := if f.rtr { 1 } else { 0 }
	st := C.ct_kvaser_write(b.handle, f.id, u8(n), f.data.data, ext, rtr)
	if st < 0 {
		return error('canWrite failed (canStatus ${st})')
	}
}

pub fn (mut b KvaserBus) recv(timeout_ms int) !CanFrame {
	// canReadWait takes an unsigned timeout; map "block forever" (negative) to a
	// large value, since the Bus contract allows timeout_ms < 0 = block.
	to := if timeout_ms < 0 { u32(0xFFFF_FFFF) } else { u32(timeout_ms) }
	mut id := u32(0)
	mut ln := u8(0)
	mut ext := 0
	mut fd := 0
	mut brs := 0
	mut esi := 0
	// 64 BYTES ALWAYS, whichever mode this handle was opened in: the shim's reader copies a full
	// FD payload out, and a classic-sized array here would be overrun by the first 64-byte frame
	// on the wire.
	mut data := [64]u8{}
	r := C.ct_kvaser_read(b.handle, &id, &ln, &data[0], &ext, &fd, &brs, &esi, to)
	if r == 1 {
		return error('timeout')
	}
	if r < 0 {
		return error('canReadWait failed (canStatus ${r})')
	}
	mut out := []u8{len: int(ln)}
	for i in 0 .. int(ln) {
		out[i] = data[i]
	}
	return CanFrame{
		id:       id & 0x1FFF_FFFF
		extended: ext != 0
		// FROM THE FRAME, not from the channel. An FD-opened channel carries classic frames too,
		// and the trace has to be able to tell them apart.
		fd:  fd != 0
		brs: brs != 0
		// A RECEIVED STATUS, not a choice the sender makes: the transmitter was error-passive.
		// The other backends carry it and a Kvaser recording must not be the one that drops it.
		esi:  esi != 0
		data: out
	}
}

pub fn (mut b KvaserBus) close() {
	C.ct_kvaser_close(b.handle)
}

// health asks canReadStatus for the canSTAT_* ladder; -1 (symbol absent in an old canlib,
// or the call failing) reads as unknown, never as a state. Decode pinned in health.v.
pub fn (mut b KvaserBus) health() BusHealth {
	mut flags := u32(0)
	if C.ct_kvaser_status(b.handle, &flags) != 0 {
		return .unknown
	}
	return kvaser_status_health(flags)
}

// kvaser_list enumerates attached Kvaser channels (physical + virtual) for discovery.
// Returns [] when canlib32.dll is absent (drivers not installed) or has no channels.
fn kvaser_list() []Iface {
	mut out := []Iface{}
	n := C.ct_kvaser_count()
	if n <= 0 {
		return out
	}
	for ch in 0 .. n {
		mut buf := [64]u8{}
		ptr := unsafe { &char(&buf[0]) }
		mut name := 'Kvaser ch${ch}'
		if C.ct_kvaser_descr(ch, ptr, 64) == 0 {
			d := unsafe { cstring_to_vstring(ptr) }.trim_space()
			if d != '' {
				name = '${d} (ch${ch})'
			}
		}
		// ASKED OF THE DRIVER. Every Kvaser channel was reported as physical, including the
		// software ones the docs send people to when they have no adapter -- so the one field
		// that would have told them which number to use said the opposite.
		out << Iface{
			name:    name
			iface:   'kvaser:${ch}'
			kind:    'can'
			virtual: C.ct_kvaser_is_virtual(ch) == 1
		}
	}
	return out
}
