// vector_windows.v — Vector XL Driver Library backend (VN1610/1630/1640, VN8900, CANcaseXL…),
// implementing the platform-agnostic `Bus` interface. Windows-only (`_windows.v` gates
// compilation). vxlapi64.dll is loaded at RUNTIME via vector_shim.h — no SDK, no import lib.
//
// Interface string: `vector:<channel>[@<bitrate>][,silent]`
//   channel : the APPLICATION channel as shown in Vector Hardware Configuration, from 1.
//             Assign hardware to it there once; opening an unassigned channel registers
//             `blobly_net` so it appears in that dialog, and says so.
//   bitrate : bits/s (default 500000)      e.g. vector:1@250000
//   ,silent : listen only — the transceiver never acknowledges, so the channel cannot
//             disturb the bus. See the note below; on a live vehicle, start here.
//
// **Silent first.** A CAN node that goes on the bus at the WRONG bitrate does not merely fail
// to read: it acknowledges nothing correctly and floods error frames, which degrades a bus
// somebody else's ECUs are using. `,silent` puts the transceiver in ACK-free mode BEFORE the
// channel is activated, which is the only ordering that is safe on a running vehicle. The
// project-level `listen_only:` flag stops US transmitting; it does not stop the transceiver
// acknowledging, because until this backend nothing below the GUI could.
//
// CLASSIC CAN ONLY. CAN-FD needs the V4 interface, xlCanFdSetConfiguration and a different
// event structure; an FD frame is refused here rather than truncated, exactly as the PCAN and
// Kvaser backends do. A VN1630A is FD-capable hardware, so this is a real limitation, not an
// absent one.
//
// SEVERAL PORTS PER CHANNEL is the normal case, not an edge one: the monitor opens its own and
// each tapped transmit path opens another, on the same wire. XL grants initialisation access to
// the first of those only, so the rest arrive with no right to set the bitrate — and the
// question they have to answer is not "may I configure this" but "is it already configured the
// way I would have". The shim answers it by remembering what this process configured, because
// XL will not report the rate a channel is running at.
//
// NOTE: written from the documented XL ABI; NOT yet verified against hardware. The event
// layout is pinned by _Static_assert in the shim, and the machine this was written on has no
// Vector hardware and no Windows. Verify with `cmd/vectorcheck` before trusting a bench to it.
module transport

#include "vector_shim.h"

fn C.ct_vector_load() int
fn C.ct_vector_open(u32, u32, int, &int, &u64, &voidptr) int
fn C.ct_vector_write(int, u64, u32, u8, &u8, int, int) int
fn C.ct_vector_read(int, voidptr, &u32, &u8, &u8, &int, &int, int) int
fn C.ct_vector_close(int, u64)
fn C.ct_vector_present(u32) int
fn C.ct_vector_diag() int
fn C.ct_vector_err(int) &char

// VectorBus is one open, activated XL port on a single channel.
pub struct VectorBus {
mut:
	port   int
	mask   u64
	notify voidptr
	silent bool
}

// VectorSpec is the parsed interface string. Separate from the open so the parsing is
// exercised by the tests in vector_names_test.v rather than only on a machine with the driver.
struct VectorSpec {
	channel int // application channel, 1-based as the operator sees it
	bitrate int
	silent  bool
}

fn parse_vector_spec(spec string) !VectorSpec {
	mut body := spec.trim_space()
	mut silent := false
	// The mode is a suffix, not part of the address: `vector:1@500000` and
	// `vector:1@500000,silent` are the SAME wire, and destination_key must see them collide or
	// the conflict check lets two owners onto one bus.
	if body.contains(',') {
		mode := body.all_after_last(',').trim_space().to_lower()
		body = body.all_before_last(',')
		match mode {
			'silent', 'listen_only', 'listenonly' { silent = true }
			'normal' { silent = false }
			else { return error('unknown Vector mode ",${mode}" (use ,silent)') }
		}
	}
	parts := body.split('@')
	ch := vector_app_channel(parts[0])!
	bitrate := if parts.len > 1 { parts[1].trim_space().int() } else { 500000 }
	// A bitrate the hardware cannot produce is a configuration error worth catching here: on a
	// live bus the consequence of getting it wrong is error frames, not a quiet failure.
	if bitrate < 5000 || bitrate > 1000000 {
		return error('Vector bitrate ${bitrate} out of range (5000..1000000)')
	}
	return VectorSpec{
		channel: ch
		bitrate: bitrate
		silent:  silent
	}
}

// open_vector parses `vector:<channel>[@<bitrate>][,silent]`, loads vxlapi64.dll, resolves the
// application channel to hardware, opens the port and activates it. Referenced only from
// open_windows.v.
pub fn open_vector(spec string) !&VectorBus {
	s := parse_vector_spec(spec)!
	mut port := 0
	mut mask := u64(0)
	mut notify := unsafe { nil }
	sil := if s.silent { 1 } else { 0 }
	// 0-BASED at the API, 1-based in the spelling: Vector Hardware Configuration numbers the
	// application channels from 1 and the operator reads the interface string against that
	// dialog, so the conversion belongs here rather than in their head.
	rc := C.ct_vector_open(u32(s.channel - 1), u32(s.bitrate), sil, &port, &mask, &notify)
	if rc == -1000 {
		return error('Vector application channel ${s.channel} has no hardware assigned — open Vector Hardware Manager, find the application "blobly_net" (registered just now) and assign a VN channel to it')
	}
	// TOLD APART. These reach the operator as the same "it did not open" and send them to
	// completely different places: a missing library is a download, an unassigned channel is a
	// dialog, and a driver that will not open is usually something else holding the hardware.
	if rc == -1 {
		// SEPARATE from the hardware drivers, which is the whole content of this message: a
		// bench can have the VN device healthy, its kernel driver loaded and Vector Hardware
		// Manager installed, and still not have this DLL anywhere on the machine. Observed
		// exactly that way on the first bench this backend met.
		return error('vxlapi64.dll not found — install the Vector XL Driver Library, which is a SEPARATE download from the hardware drivers (the device and Vector Hardware Manager can be installed without it)')
	}
	if rc == -2 {
		return error('vxlapi64.dll is missing functions this backend needs — update the Vector XL Driver Library')
	}
	if rc == -1003 {
		return error('Vector channel ${s.channel}: another application holds initialisation access, so the bitrate cannot be set — close the other XL application (CANoe, CANalyzer, a second copy of this one) and try again')
	}
	// These two mean the channel is already open IN THIS PROCESS with different settings, which
	// is a project asking one wire to be two things rather than anything about the hardware.
	if rc == -1004 {
		return error('Vector channel ${s.channel} is already open in normal mode by this project — it cannot also be listen-only; make every channel on this wire agree')
	}
	if rc == -1006 {
		return error('Vector: more than 64 channels are already open in this process — refusing rather than opening one whose later ports would all be denied')
	}
	if rc == -1005 {
		return error('Vector channel ${s.channel} is already open at a different bitrate by this project — one wire cannot run at two rates')
	}
	if rc == -1002 {
		return error('this vxlapi build cannot set silent mode, and ,silent was asked for — refusing to go on the bus able to acknowledge')
	}
	if rc != 0 {
		msg := unsafe { cstring_to_vstring(C.ct_vector_err(-rc)) }
		extra := if msg == '' { '' } else { ' (${msg})' }
		return error('Vector channel ${s.channel} failed to open (XL status ${-rc})${extra}')
	}
	return &VectorBus{
		port:   port
		mask:   mask
		notify: notify
		silent: s.silent
	}
}

pub fn (mut b VectorBus) send(f CanFrame) ! {
	// SILENCE IS A PROMISE. A channel opened `,silent` was opened that way because something
	// live is on the other end; the transceiver will not acknowledge, so the frame could not
	// arrive anyway, and reporting success for it would put a row in the trace for traffic that
	// never existed.
	if b.silent {
		return error('Vector: this channel is open in silent mode and cannot transmit (id 0x${f.id:X})')
	}
	if f.fd {
		return error('Vector: CAN-FD frames are not supported by this backend yet (id 0x${f.id:X}, ${f.data.len} bytes)')
	}
	// REFUSED, not truncated. `vector:` is a vendor interface, so clamps_to_classic() is false
	// and wire_frame() hands the trace the frame AS ASKED — nine bytes recorded, eight on the
	// wire, and an echo that can never match its own record. The vendor drivers reject a
	// malformed frame; this backend must not quietly turn that into a valid-but-different
	// transmission.
	if f.data.len > 8 {
		return error('Vector: ${f.data.len} bytes is not a classic CAN frame (id 0x${f.id:X}) — 8 is the maximum without FD')
	}
	n := f.data.len
	ext := if f.extended { 1 } else { 0 }
	// RTR is carried, not dropped. A remote request with the bit lost goes out as an ordinary
	// zero-length data frame and is reported as success — a different message than the caller
	// asked for, on the wire, with nothing to say so.
	rtr := if f.rtr { 1 } else { 0 }
	st := C.ct_vector_write(b.port, b.mask, f.id, u8(n), f.data.data, ext, rtr)
	if st != 0 {
		msg := unsafe { cstring_to_vstring(C.ct_vector_err(-st)) }
		extra := if msg == '' { '' } else { ' (${msg})' }
		return error('xlCanTransmit failed (XL status ${-st})${extra}')
	}
}

pub fn (mut b VectorBus) recv(timeout_ms int) !CanFrame {
	mut id := u32(0)
	mut ln := u8(0)
	mut ext := 0
	mut rtr := 0
	mut data := [8]u8{}
	r := C.ct_vector_read(b.port, b.notify, &id, &ln, &data[0], &ext, &rtr, timeout_ms)
	if r == 1 {
		return error('timeout')
	}
	if r < 0 {
		msg := unsafe { cstring_to_vstring(C.ct_vector_err(-r)) }
		extra := if msg == '' { '' } else { ' (${msg})' }
		return error('xlReceive failed (XL status ${-r})${extra}')
	}
	mut out := []u8{len: int(ln)}
	for i in 0 .. int(ln) {
		out[i] = data[i]
	}
	return CanFrame{
		id:       id & 0x1FFF_FFFF
		extended: ext != 0
		rtr:      rtr != 0
		data:     out
	}
}

pub fn (mut b VectorBus) close() {
	C.ct_vector_close(b.port, b.mask)
}

// vector_list reports the application channels that have hardware assigned, for discovery.
// Returns [] when vxlapi64.dll is absent.
//
// It lists what is CONFIGURED, not what is plugged in — the XL library addresses application
// channels, and a VN1630A nobody has assigned yet appears here only once the operator has
// pointed a channel at it in Vector Hardware Configuration. Reporting the physical device
// list instead would need XLdriverConfig, whose layout this backend deliberately does not
// reproduce; see the note at the top of vector_shim.h.
// vector_driver_status reports whether the XL driver is usable at all, separately from whether
// any channel is assigned: 0 usable, -1 vxlapi64.dll absent, -2 a needed symbol missing, other
// negatives an XL status from xlOpenDriver.
pub fn vector_driver_status() int {
	return C.ct_vector_diag()
}

fn vector_list() []Iface {
	mut out := []Iface{}
	if C.ct_vector_load() != 0 {
		return out
	}
	for ch in 1 .. 9 {
		if C.ct_vector_present(u32(ch - 1)) == 0 {
			continue
		}
		out << Iface{
			name:    'Vector application channel ${ch}'
			iface:   'vector:${ch}'
			kind:    'can'
			virtual: false
		}
	}
	return out
}
