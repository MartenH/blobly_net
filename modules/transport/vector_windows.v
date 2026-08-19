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
// ABI CHECKED against vxlapi.h 25.20.14 (shipped with the XL Driver Library, not with the
// hardware drivers): every typedef, signature and constant this backend uses matches, and
// _Static_assert pins the event layout at build time. The driver loads, resolves and opens —
// xlOpenDriver returns XL_SUCCESS on a real VN1630A bench.
//
// STILL UNPROVEN: a frame. Nothing has been transmitted or received, because no application
// channel has hardware assigned to it yet. `cmd/vectorcheck` is the way to close that gap, and
// it opens silently so the first attempt cannot disturb a live bus.
module transport

#include "vector_shim.h"

fn C.ct_vector_load() int
fn C.ct_vector_open(u32, u32, int, &int, &u64, &voidptr, &u64) int
fn C.ct_vector_write(int, u64, u32, u8, &u8, int, int) int
fn C.ct_vector_read(int, voidptr, &u32, &u8, &u8, &int, &int, int) int
fn C.ct_vector_close(int, u64, u64, voidptr)
fn C.ct_vector_present(u32) int
fn C.ct_vector_diag() int
fn C.ct_vector_dll_path() &char
fn C.ct_vector_assign(u32, int, int, int) int
fn C.ct_vector_appl_get(u32, &int, &int, &int) int
fn C.ct_vector_probe(int, &int, &int, &int, &u64) int
fn C.ct_vector_channel_info(int, &char, int, &char, int, &int, &int, &int, &u32, &u32, &u32, &int, &int) int
fn C.ct_vector_error_frames() int
fn C.ct_vector_chipstate(int, u64, &int, &int, &int) int
fn C.ct_vector_set_verbose(int)
fn C.ct_vector_err(int) &char

// vector_busy_msg prefixes the one error that means "slow down", so callers can recognise it
// without matching on an XL status number they should not have to know.
pub const vector_busy_msg = 'vector: busy'

// VectorBus is one open, activated XL port on a single channel.
pub struct VectorBus {
mut:
	port   int
	mask   u64
	gen    u64 // which open of this channel we are; see the generation note in vector_shim.h
	notify voidptr
	silent bool
}

// open_vector parses `vector:<channel>[@<bitrate>][,silent]`, loads vxlapi64.dll, resolves the
// application channel to hardware, opens the port and activates it. Referenced only from
// open_windows.v.
pub fn open_vector(spec string) !&VectorBus {
	s := parse_vector_spec(spec)!
	mut port := 0
	mut mask := u64(0)
	mut notify := unsafe { nil }
	mut gen := u64(0)
	sil := if s.silent { 1 } else { 0 }
	// 0-BASED at the API, 1-based in the spelling: Vector Hardware Configuration numbers the
	// application channels from 1 and the operator reads the interface string against that
	// dialog, so the conversion belongs here rather than in their head.
	rc := C.ct_vector_open(u32(s.channel - 1), u32(s.bitrate), sil, &port, &mask, &notify, &gen)
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
		gen:    gen
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
	if st == -2000 {
		// The WIRE is the limit, not the bench. Named distinctly so a caller can back off and
		// retry: a replay of a busy capture will reach this whenever it is asked to go faster
		// than the bus, and treating it as a failure would end the run over a full buffer.
		return error('${vector_busy_msg}: the transmit queue is full (id 0x${f.id:X})')
	}
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
	// ONCE. A second close would release a reference this port no longer holds, and the record
	// it decremented would belong to whoever opened the wire next. Callers close via `defer` in
	// several places and a Bus may be closed by its owner and again on teardown; the port handle
	// is the flag because it is the thing that stops being valid.
	if b.port < 0 {
		return
	}
	C.ct_vector_close(b.port, b.mask, b.gen, b.notify)
	b.port = -1
	b.notify = unsafe { nil }
}

// VectorHw is one hardware channel the driver admits to having.
pub struct VectorHw {
pub:
	hw_type    int
	hw_index   int
	hw_channel int
	mask       u64
}

// vector_hardware asks the DRIVER what is present, rather than matching a table of device types
// that would go stale every time Vector ships one. xlGetChannelMask is a pure lookup returning
// zero for hardware that is not there.
pub fn vector_hardware() []VectorHw {
	mut out := []VectorHw{}
	for i in 0 .. 64 {
		mut ht := 0
		mut hi := 0
		mut hc := 0
		mut m := u64(0)
		if C.ct_vector_probe(i, &ht, &hi, &hc, &m) != 0 {
			break
		}
		out << VectorHw{
			hw_type:    ht
			hw_index:   hi
			hw_channel: hc
			mask:       m
		}
	}
	return out
}

// vector_assignment reports what an application channel currently points at, or none when it
// has no hardware. Registers nothing, so it is safe to ask about channels we do not own.
pub fn vector_assignment(app_channel int) ?VectorChannel {
	mut ht := 0
	mut hi := 0
	mut hc := 0
	if C.ct_vector_appl_get(u32(app_channel - 1), &ht, &hi, &hc) != 0 {
		return none
	}
	return VectorChannel{
		hw_type:    ht
		hw_index:   hi
		hw_channel: hc
	}
}

// vector_assign points one of OUR application channels at a piece of hardware, as Vector
// Hardware Manager would. It writes only under the name `blobly_net`, so another application's
// assignment cannot be disturbed by it.
// Takes the channel AS THE DRIVER DESCRIBES IT, not an index into some other list. It used to
// take a VectorHw from a separate probe sweep, and the two lists were in different orders —
// the driver reports its channels device-first, the sweep walks hwType ascending, so row 0 was
// "VN1630A Channel 1" in the table and the virtual channel in the assignment. The caller named
// one thing and got another, and the only symptom was silence on a wire that was fine.
pub fn vector_assign(app_channel int, hw VectorChannel) ! {
	rc := C.ct_vector_assign(u32(app_channel - 1), hw.hw_type, hw.hw_index, hw.hw_channel)
	if rc != 0 {
		return error('assigning Vector application channel ${app_channel} failed (XL status ${-rc})')
	}
}

// VectorChannel is one channel as the DRIVER describes it — the bench's own view, not ours.
pub struct VectorChannel {
pub:
	name        string // e.g. "VN1630A Channel 1"
	transceiver string // e.g. "On board CAN 1051cap"
	hw_type     int
	hw_index    int
	hw_channel  int
	serial      u32
	bus_type    u32 // what it is CONNECTED as (1 = CAN); 0 when nothing is configured
	bitrate     u32 // the rate the channel is currently configured for
	on_bus      bool
	trx_state   int // XL_TRANSCEIVER_STATUS_*: 0 = no transceiver seen on this channel
}

// vector_channels reads the Vector hardware configuration: every channel the driver knows
// about, with the device name, transceiver, serial number, the bus it is wired as and the rate
// it is set to. This is what Vector Hardware Manager shows, from the same source.
pub fn vector_channels() []VectorChannel {
	mut out := []VectorChannel{}
	for i in 0 .. 64 {
		mut nm := [33]u8{}
		mut tr := [33]u8{}
		mut ht := 0
		mut hi := 0
		mut hc := 0
		mut sn := u32(0)
		mut bt := u32(0)
		mut br := u32(0)
		mut ob := 0
		mut ts := 0
		rc := C.ct_vector_channel_info(i, unsafe { &char(&nm[0]) }, 33, unsafe { &char(&tr[0]) },
			33, &ht, &hi, &hc, &sn, &bt, &br, &ob, &ts)
		if rc != 0 {
			break
		}
		out << VectorChannel{
			name:        unsafe { cstring_to_vstring(&char(&nm[0])) }.trim_space()
			transceiver: unsafe { cstring_to_vstring(&char(&tr[0])) }.trim_space()
			hw_type:     ht
			hw_index:    hi
			hw_channel:  hc
			serial:      sn
			bus_type:    bt
			bitrate:     br
			on_bus:      ob != 0
			trx_state:   ts
		}
	}
	return out
}

// vector_error_frames is how many error frames this process has seen. On a bus we cannot decode
// it is the difference between "nothing is there" and "something is there and we have the rate
// wrong" — a silent node sees error frames and nothing else.
// VectorChipState is what the CAN controller says about itself.
pub struct VectorChipState {
pub:
	bus_status int // XL_CHIPSTAT_*: 8 = error active (healthy), 2 = error passive, 1 = bus off
	tx_errors  int
	rx_errors  int
}

// chip_state asks this channel's controller how it is doing. A transmit that produced no
// traffic is ambiguous until you look here: unacknowledged frames drive tx_errors up, while a
// frame that never reached the wire leaves the counters alone.
pub fn (b &VectorBus) chip_state() !VectorChipState {
	mut bs := 0
	mut tx := 0
	mut rx := 0
	if C.ct_vector_chipstate(b.port, b.mask, &bs, &tx, &rx) != 0 {
		return error('the controller did not report its state')
	}
	return VectorChipState{
		bus_status: bs
		tx_errors:  tx
		rx_errors:  rx
	}
}

// chip_state_of asks a Bus for its controller state, when it is a Vector one. The type switch
// lives here rather than at the call site: `Bus` is this module's interface and the concrete
// types behind it are this module's business.
pub fn chip_state_of(b Bus) ?VectorChipState {
	if b is VectorBus {
		return b.chip_state() or { return none }
	}
	return none
}

// vector_verbose makes the backend narrate each XL call it makes. For working out which of them
// returned success without doing anything.
pub fn vector_verbose(on bool) {
	C.ct_vector_set_verbose(if on { 1 } else { 0 })
}

pub fn vector_error_frames() int {
	return C.ct_vector_error_frames()
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

// vector_driver_path is the vxlapi the process actually loaded, or '' if none. Worth reporting:
// the library does not install onto the search path, so "which copy is this" is a real question
// on a machine that may also have one beside an executable or in System32.
pub fn vector_driver_path() string {
	p := C.ct_vector_dll_path()
	if p == unsafe { nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(p) }
}

fn vector_list() []Iface {
	mut out := []Iface{}
	if C.ct_vector_load() != 0 {
		return out
	}
	// THE WHOLE SUPPORTED RANGE, matching vector_app_channel and the shim's table. Stopping at
	// eight hid hardware assigned to a higher application channel and made --list report that
	// nothing was assigned at all — the same mistake as sizing the configuration table by what
	// a bench plausibly has. Probing does not register anything, so sweeping 64 costs nothing
	// but the lookups.
	for ch in 1 .. 65 {
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
