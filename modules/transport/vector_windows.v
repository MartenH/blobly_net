// vector_windows.v — Vector XL Driver Library backend (VN1610/1630/1640, VN8900, CANcaseXL…),
// implementing the platform-agnostic `Bus` interface. Windows-only (`_windows.v` gates
// compilation). vxlapi64.dll is loaded at RUNTIME via vector_shim.h — no SDK, no import lib.
//
// Interface string: `vector:<channel>[@<bitrate>[/<data bitrate>]][,silent]`
//   channel : the APPLICATION channel as shown in Vector Hardware Configuration, from 1.
//             Assign hardware to it there once; opening an unassigned channel registers
//             `blobly_net` so it appears in that dialog, and says so.
//   bitrate : bits/s (default 500000)      e.g. vector:1@250000
//   /<rate> : CAN-FD, with that data-phase rate  e.g. vector:1@500000/2000000
//             Its presence is what asks for FD; `@500000/500000` is FD with no bit-rate switch.
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
// CAN-FD is supported, and it is a property of the ADDRESS rather than of a frame: the data
// bitrate in `@<arb>/<data>` is what selects it, because the payload phase has to be configured
// before the channel goes on the bus and `open` is all the backend is given. An FD address opens
// the port at XL interface V4 and configures both phases with xlCanFdSetConfiguration; a classic
// address opens V3 exactly as before. The two are not interchangeable — a V4 port must be read
// with xlCanReceive and written with xlCanTransmitEx — so which one a port is travels with it in
// `VectorBus.fd` and is pinned across the ports of one channel like the bitrate is.
//
// An FD-configured channel still carries CLASSIC frames: `fd` on the frame sets EDL, `brs` the
// bit-rate switch. What is refused is an FD frame on a CLASSIC channel, because there is nothing
// truthful to do with it — see send().
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
// HARDWARE-VERIFIED on a VN1630A (serial 545980, 2026-08-19): Channel 1 to Channel 3 over real
// transceivers, 43,773 frames sent and received with none malformed and the sequence numbers
// checked, at bus saturation for 500 kbit/s. `cmd/vectorcheck --selftest` repeats the same proof
// on Vector's software virtual channels, which need no hardware and touch no real bus.
//
// CAN-FD verified on the same adapter (2026-08-24): 64-byte payloads with BRS at data phases of
// 2, 4, 5 and 8 Mbit/s, every byte of every payload checked against what was sent — 100%
// arrived, none malformed. `--modecheck` proves the protocol pin in all four directions against
// the driver. The table is in docs/windows_can_hardware.md.
module transport

import time

#include "vector_shim.h"

fn C.ct_vector_load() int
fn C.ct_vector_open(u32, u32, int, &int, &u64, &voidptr, &u64, int, u32, u32, u32, u32, u32, u32, u32) int
fn C.ct_vector_write(int, u64, u32, u8, &u8, int, int) int
fn C.ct_vector_write_fd(int, u64, u32, u8, &u8, int, int, int, int, &u8) int
fn C.ct_vector_read(int, voidptr, &u32, &u8, &u8, &int, &int, int, &int, int, &int, &int, &int) int
fn C.ct_vector_close(int, u64, u64, voidptr)
fn C.ct_vector_present(u32) int
fn C.ct_vector_diag() int
fn C.ct_vector_dll_path() &char
fn C.ct_vector_assign(u32, int, int, int) int
fn C.ct_vector_appl_get(u32, &int, &int, &int) int
fn C.ct_vector_borrow_lock() int
fn C.ct_vector_borrow_lock_for(u32) int
fn C.ct_vector_borrow_unlock()
fn C.ct_vector_probe(int, &int, &int, &int, &u64) int
fn C.ct_vector_channel_info(int, &char, int, &char, int, &int, &int, &int, &u32, &u32, &u32, &int, &int, &int, &int, &int) int
fn C.ct_vector_error_frames() int
fn C.ct_vector_chipstate(int, u64, &int, &int, &int, int) int
fn C.ct_vector_reqchip(int, u64) int
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
	// WHICH INTERFACE VERSION THIS PORT WAS OPENED WITH, and therefore which of the two event
	// encodings its queue carries. Not a preference that send/recv could reconsider per frame:
	// reading a V4 queue with xlReceive decodes the first 48 bytes of a 128-byte event as if they
	// were a classic one. Set once at open and never written again.
	fd bool
	// last chip-state busStatus captured by recv from the event stream (-1 = none yet).
	// health() only REQUESTS a report; the reply rides the queue the reader is already
	// emptying — the drain-and-hunt alternative lost data frames mid-run (self-review).
	last_chip int = -1
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
	isfd := if s.fd { 1 } else { 0 }
	// FOR AN FD PORT ONLY, AND THAT IS THE WHOLE CONDITION. A classic open does not use these
	// segments at all — the shim's classic branch calls xlCanSetChannelBitrate and lets the DRIVER
	// work out the timing — so deriving them there answers a question nobody asked, and refusing
	// when the answer does not exist breaks opens that have always worked.
	//
	// It did: 83333 bit/s is an ordinary CAN rate on real buses and 80e6/83333 is 960.0038, so no
	// prescaler produces it from this clock. The driver has its own answer for that and had been
	// giving it; this validation stepped in front of it and refused the channel (codex #182 r1).
	// The FD path has no such fallback — XLcanFdConf takes the segments and nothing derives them
	// for us — which is exactly why the check belongs to that path and only that path.
	//
	// A TIMING PER PHASE within it. Each reaches the same ~80% sample point with its own quanta
	// count and its own prescaler; requiring them to share a count refuses rate pairs the hardware
	// can do, and applying the data phase's narrower ceiling to both refuses more (#181 r5, r6).
	// THROUGH THE SHARED CHECK, so that what a front end can ask beforehand and what this refuses
	// are the same question. They were not: the editor's pre-flight ran the parser only, so an
	// address it accepted could still fail here on timing (codex #183 r2). vector_timing_error is
	// now the one definition of "these rates are producible", and vector_address_error — what the
	// editor calls — runs it too.
	if why := vector_timing_error(s) {
		return error('Vector channel ${s.channel}: ${why}')
	}
	mut at := FdTiming{}
	mut dt := FdTiming{}
	if s.fd {
		// Cannot fail: vector_timing_error just proved both phases resolve.
		at = vector_fd_timing(s.bitrate) or { FdTiming{} }
		dt = vector_fd_timing_data(s.data_bitrate) or { FdTiming{} }
	}
	// 0-BASED at the API, 1-based in the spelling: Vector Hardware Configuration numbers the
	// application channels from 1 and the operator reads the interface string against that
	// dialog, so the conversion belongs here rather than in their head.
	mut rc := C.ct_vector_open(u32(s.channel - 1), u32(s.bitrate), sil, &port, &mask, &notify,
		&gen, isfd, u32(s.data_bitrate), u32(at.tseg1), u32(at.tseg2), u32(at.sjw), u32(dt.tseg1),
		u32(dt.tseg2), u32(dt.sjw))
	// WAIT OUT A WINDING-DOWN RUN. -1009 means the previous run's ports are still closing, which
	// is what an immediate Stop/Start looks like from here; it clears itself when the last one
	// goes. Bounded, because a port that never closes must not hang the open forever.
	for _ in 0 .. 200 {
		if rc != -1009 {
			break
		}
		time.sleep(10 * time.millisecond)
		rc = C.ct_vector_open(u32(s.channel - 1), u32(s.bitrate), sil, &port, &mask, &notify,
			&gen, isfd, u32(s.data_bitrate), u32(at.tseg1), u32(at.tseg2), u32(at.sjw),
			u32(dt.tseg1), u32(dt.tseg2), u32(dt.sjw))
	}
	if rc == -1009 {
		return error('Vector channel ${s.channel} is still being released by the previous run — try again in a moment')
	}
	if rc == -1008 {
		return error('Vector application channel ${s.channel} has no hardware assigned, and registering the application "blobly_net" failed — so it will NOT appear in Vector Hardware Manager to be assigned. Check the XL Driver Library version.')
	}
	if rc == -1007 {
		return error('Vector application channel ${s.channel}: the driver would not report what it is assigned to. Nothing was changed; try again, and check that no other XL application is mid-restart.')
	}
	if rc == -1001 {
		return error('Vector application channel ${s.channel} is assigned to hardware that is not present — the adapter it names is unplugged, powered off, or claimed by another application. The assignment itself is fine.')
	}
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
		// WHICHEVER WAY ROUND, derived rather than assumed. The shim's check is bidirectional
		// and says so; this message was not, and named the mode backwards for half the cases it
		// covers — observed on a VN1630A by `--modecheck`, which holds a channel LISTEN-ONLY and
		// was told the channel was open in normal mode. rc -1004 means only that the channel's
		// mode differs from the one asked for, so the channel is in the other one.
		has := if s.silent { 'normal' } else { 'listen-only' }
		want := if s.silent { 'listen-only' } else { 'normal' }
		return error('Vector channel ${s.channel} is already open in ${has} mode by this project and cannot also be ${want} — the configuration belongs to the ports open on this channel, so make every channel on this wire agree, or Stop and Start to change it')
	}
	if rc == -1006 {
		return error('Vector: more than 64 channels are already open in this process — refusing rather than opening one whose later ports would all be denied')
	}
	if rc == -1005 {
		return error('Vector channel ${s.channel} is already open at a different bitrate by this project — one wire cannot run at two rates')
	}
	if rc == -1010 {
		return error('this vxlapi build has no CAN-FD support (xlCanFdSetConfiguration, xlCanTransmitEx and xlCanReceive are all needed) — update the Vector XL Driver Library, or address this channel as classic CAN by dropping the "/${s.data_bitrate}" from its bitrate')
	}
	// The FD half of -1004/-1005: same rule, same reason, and told apart because the two send an
	// operator to different places — one is a protocol disagreement between rows, the other a
	// data-rate one between rows that already agree the wire is FD.
	if rc == -1011 {
		has := if s.fd { 'classic CAN' } else { 'CAN-FD' }
		want := if s.fd { 'CAN-FD' } else { 'classic CAN' }
		return error('Vector channel ${s.channel} is already open as ${has} by this project and cannot also be ${want} — the protocol belongs to the ports open on this channel, so make every channel on this wire agree, or Stop and Start to change it')
	}
	if rc == -1012 {
		return error('Vector channel ${s.channel} is already open with a different CAN-FD data bitrate by this project — one wire cannot run two data phases')
	}
	if rc == -1002 {
		return error('this vxlapi build has no xlCanSetChannelOutput, so the transceiver mode can be neither set nor read — refusing rather than guessing whether this channel would acknowledge. Update the Vector XL Driver Library.')
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
		fd:     s.fd
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
	// THE CHANNEL'S PROTOCOL, not the frame's wish. An FD frame on a channel configured for
	// classic CAN has nowhere truthful to go: the port is open at interface V3, the transceiver
	// was never given a data phase, and the alternatives to refusing are to truncate the payload
	// (a different message, on the wire, reported as this one) or to send it as classic at the
	// arbitration rate (which is not what the caller asked for either). Named as a channel
	// configuration problem, because that is what fixes it.
	if f.fd && !b.fd {
		return error('Vector: this channel is open as classic CAN and cannot send a CAN-FD frame (id 0x${f.id:X}, ${f.data.len} bytes) — give its address a data bitrate, as vector:<n>@500000/2000000, or set the channel type to canfd in the project')
	}
	if f.brs && !f.fd {
		// The library's XL_ERR_EDL_NOT_SET, refused here where it can be explained: the bit-rate
		// switch is what an FD frame does BETWEEN its phases, so a classic frame has no phase to
		// switch to.
		return error('Vector: brs is set on a frame that is not FD (id 0x${f.id:X}) — the bit-rate switch belongs to a CAN-FD frame')
	}
	// REFUSED, not truncated. `vector:` is a vendor interface, so clamps_to_classic() is false
	// and wire_frame() hands the trace the frame AS ASKED — nine bytes recorded, eight on the
	// wire, and an echo that can never match its own record. The vendor drivers reject a
	// malformed frame; this backend must not quietly turn that into a valid-but-different
	// transmission.
	//
	// STILL 8 FOR A NON-FD FRAME on an FD channel: the limit belongs to the frame format, not to
	// the channel. A 12-byte payload with `fd` unset is as malformed on an FD wire as anywhere.
	if !f.fd && f.data.len > 8 {
		return error('Vector: ${f.data.len} bytes is not a classic CAN frame (id 0x${f.id:X}) — 8 is the maximum without FD')
	}
	if f.data.len > 64 {
		return error('Vector: ${f.data.len} bytes does not fit a CAN-FD frame (id 0x${f.id:X}) — 64 is the maximum')
	}
	// BEFORE THE TRANSMIT, not after it. Above eight bytes CAN-FD carries only the sizes a DLC can
	// encode, so a 9-byte payload goes out as 12 with the remainder padded — and the trace would
	// then record a length the wire never carried, the same record-versus-wire disagreement the
	// classic path refuses a 9-byte frame to avoid.
	//
	// The first draft of this compared the shim's reported on-wire length AFTER the call, which
	// refused the frame having already sent it — an error returned for a transmission that
	// happened, which is worse than either padding silently or refusing cleanly. The check belongs
	// where it can still prevent something.
	if f.fd && f.data.len !in fd_lengths {
		return error('Vector: ${f.data.len} bytes is not a CAN-FD payload size (id 0x${f.id:X}) — a DLC can only express ${fd_lengths}, so this would go out padded; pad it deliberately and the trace will match the wire')
	}
	// THE ID AGAINST ITS DECLARED WIDTH, which cannot be left to XL: the shim marks an extended
	// frame by setting bit 31 of the identifier, so `id: 0x80000001, extended: false` already
	// carries that flag and goes out extended while the trace records it as standard. Values
	// above the width are equally a lie — a standard frame cannot hold 0x800.
	limit := if f.extended { u32(0x1FFF_FFFF) } else { u32(0x7FF) }
	if f.id > limit {
		width := if f.extended { '29-bit' } else { '11-bit' }
		return error('Vector: id 0x${f.id:X} does not fit a ${width} identifier')
	}
	n := f.data.len
	ext := if f.extended { 1 } else { 0 }
	// RTR is carried, not dropped. A remote request with the bit lost goes out as an ordinary
	// zero-length data frame and is reported as success — a different message than the caller
	// asked for, on the wire, with nothing to say so.
	rtr := if f.rtr { 1 } else { 0 }
	// WHICHEVER CALL MATCHES THE PORT. xlCanTransmit on a V4 port and xlCanTransmitEx on a V3 one
	// are both wrong at the ABI level, so this follows `b.fd` — the port's own version — and not
	// `f.fd`, which is only what this frame wants to be.
	mut st := 0
	if b.fd {
		mut on_wire := u8(0)
		fdflag := if f.fd { 1 } else { 0 }
		brs := if f.brs { 1 } else { 0 }
		st = C.ct_vector_write_fd(b.port, b.mask, f.id, u8(n), f.data.data, ext, rtr, fdflag,
			brs, &on_wire)
		// A BACKSTOP, and it must not report failure: the length was checked against fd_lengths
		// above, so reaching here means the shim padded a length this function believed exact —
		// a disagreement between the two tables rather than anything the caller did. The frame
		// HAS gone out, so returning an error would report a transmission that happened as one
		// that did not; the frame is what it is, and the mismatch belongs where a developer sees
		// it rather than in a send that the caller would retry.
		if st == 0 && int(on_wire) != n {
			eprintln('vector: BUG — ${n} bytes went out as ${on_wire}; fd_lengths and ct_fd_dlc_for_len disagree')
		}
	} else {
		st = C.ct_vector_write(b.port, b.mask, f.id, u8(n), f.data.data, ext, rtr)
	}
	if st == -2001 {
		return error('Vector: a CAN-FD frame cannot also be a remote request (id 0x${f.id:X}) — RTR does not exist in FD')
	}
	if st == -2002 {
		return error('Vector: brs without fd (id 0x${f.id:X})')
	}
	if st == -2003 {
		return error('Vector: ${n} bytes cannot be carried by this frame format (id 0x${f.id:X})')
	}
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
	// 64 ALWAYS, not 8 on a classic channel. The shim writes at most `ln` bytes and a V3 decode
	// never sets `ln` above 8, so the extra bytes cost one stack frame's worth of nothing — while
	// a buffer sized by the channel's protocol would be an 8-byte array behind a pointer the FD
	// decoder writes 64 bytes through the moment the two ever disagree.
	mut data := [64]u8{}
	mut chip := -1
	mut isfd := 0
	mut brs := 0
	mut esi := 0
	pfd := if b.fd { 1 } else { 0 }
	r := C.ct_vector_read(b.port, b.notify, &id, &ln, &data[0], &ext, &rtr, timeout_ms, &chip,
		pfd, &isfd, &brs, &esi)
	if chip >= 0 {
		b.last_chip = chip
	}
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
		fd:       isfd != 0
		brs:      brs != 0
		esi:      esi != 0
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

// vector_assignment reports what an application channel points at: the channel and true, or a
// blank and false when nothing is assigned. It ERRORS only when the DRIVER could not be asked —
// distinct from "nothing is assigned", because a caller about to overwrite the mapping must not
// treat an unanswered question as a free channel. Registers nothing.
//
// -3 ERRORS, IT DOES NOT REPORT "UNASSIGNED". An earlier revision flattened it to "nothing here",
// on the reasoning that an unregistered channel points at no hardware — which is true, but -3 rests
// on XL's GENERIC error and so is also what one momentary failure on an OCCUPIED channel looks
// like. `borrow` below reads this to snapshot what it is about to overwrite, and its own comment
// records what a false "free" costs there: it restored the channel by clearing a mapping the
// operator had made. Only `-2` is the driver positively saying the channel is registered and
// empty; everything else is a question this function could not answer (codex #192 r9).
//
// A caller that must distinguish "no such channel" from "could not read" wants vector_app_slot,
// which keeps the four states apart and confirms the ambiguous one before anything is written.
pub fn vector_assignment(app_channel int) !(VectorChannel, bool) {
	mut ht := 0
	mut hi := 0
	mut hc := 0
	rc := C.ct_vector_appl_get(u32(app_channel - 1), &ht, &hi, &hc)
	if rc == -2 {
		return VectorChannel{}, false
	}
	if rc != 0 {
		return error('could not read the assignment of Vector application channel ${app_channel}')
	}
	return VectorChannel{
		hw_type:    ht
		hw_index:   hi
		hw_channel: hc
	}, true
}

// appl_get_code asks about one channel and returns the raw code, without the two-state flattening
// vector_assignment does. `slot_of` lives in vector_names.v, where the tests can reach it.
fn appl_get_code(app_channel int) int {
	mut ht := 0
	mut hi := 0
	mut hc := 0
	return C.ct_vector_appl_get(u32(app_channel - 1), &ht, &hi, &hc)
}

// vector_borrow_lock / vector_borrow_unlock bracket a read-modify-restore of the application
// channel assignments, across PROCESSES. Two diagnostics running at once would otherwise
// interleave their saves and restores and leave a channel pointed somewhere nobody chose.
// vector_borrow_lock_now takes the same interprocess lock but gives up quickly, for a caller that
// must not block — the GUI render thread. Losing the race is reported, not waited out: a frozen
// window for as long as another process holds the mutex is worse than "try again" (codex #192 r4).
pub fn vector_borrow_lock_now() ! {
	if C.ct_vector_borrow_lock_for(u32(250)) != 0 {
		return error('another Vector tool is changing the application channels just now — try again in a moment')
	}
}

pub fn vector_borrow_lock() ! {
	if C.ct_vector_borrow_lock() != 0 {
		return error('another Vector diagnostic is holding the application channels; waited a minute')
	}
}

pub fn vector_borrow_unlock() {
	C.ct_vector_borrow_unlock()
}

// vector_unassign returns one of our application channels to having no hardware, which is what
// "as we found it" means for a channel that was unassigned before we borrowed it. hwType 0 is
// how the XL library spells unassigned, and it is the same call that registers the application
// in the first place.
pub fn vector_unassign(app_channel int) ! {
	rc := C.ct_vector_assign(u32(app_channel - 1), 0, 0, 0)
	if rc != 0 {
		return error('clearing Vector application channel ${app_channel} failed (XL status ${-rc})')
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
	// WHETHER THIS CHANNEL CAN CARRY CAN-FD, straight from the driver rather than inferred from
	// the transceiver's part number — which was the only route before, and is not one a dialog
	// can take on the operator's behalf (#187).
	//
	// TWO FLAGS, not one, because ISO and Bosch CAN-FD are different frame formats: ISO
	// 11898-1:2015 changed the CRC and added the stuff-count, so the two do not interoperate.
	// This backend always configures ISO (`XLcanFdConf.options` left at 0), so `fd_bosch` without
	// `fd_iso` is a channel we cannot drive — and reporting a flat "FD" for it would promise
	// something the open then refuses.
	fd_iso   bool
	fd_bosch bool
	// WHETHER THIS IS A CAN CHANNEL AT ALL. XLdriverConfig lists everything a device has, and a
	// VN1630A reports a D/A IO channel beside its four CAN ones — while everything in this module
	// addresses CAN. Offering to assign one produces a mapping that can only fail to open as the
	// interface it was advertised as (codex #192 r1). From channelBusCapabilities, which is what
	// the channel COULD be rather than what it is currently connected as.
	can_capable bool
}

// fd_capable reports whether this channel can carry the CAN-FD this backend actually configures.
// Deliberately NOT `fd_iso || fd_bosch`: we send ISO frames, so a Bosch-only channel is not one
// an FD project row can be pointed at, whatever the hardware is capable of in principle.
pub fn (c VectorChannel) fd_capable() bool {
	return c.fd_iso
}

// fd_note is the one-word summary a listing shows: what this channel offers, in the terms an
// operator picking hardware needs — blank when it offers no FD at all.
pub fn (c VectorChannel) fd_note() string {
	return if c.fd_iso && c.fd_bosch {
		'iso+bosch'
	} else if c.fd_iso {
		'iso'
	} else if c.fd_bosch {
		'bosch-only' // real FD hardware, but not the variant this backend speaks
	} else {
		''
	}
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
		mut fiso := 0
		mut fbosch := 0
		mut cancap := 0
		rc := C.ct_vector_channel_info(i, unsafe { &char(&nm[0]) }, 33, unsafe { &char(&tr[0]) },
			33, &ht, &hi, &hc, &sn, &bt, &br, &ob, &ts, &fiso, &fbosch, &cancap)
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
			fd_iso:      fiso != 0
			fd_bosch:    fbosch != 0
			can_capable: cancap != 0
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
	if C.ct_vector_chipstate(b.port, b.mask, &bs, &tx, &rx, if b.fd { 1 } else { 0 }) != 0 {
		return error('the controller did not report its state')
	}
	return VectorChipState{
		bus_status: bs
		tx_errors:  tx
		rx_errors:  rx
	}
}

// health returns the last chip state the RECV STREAM carried and fires the next async
// request. The first draft polled ct_vector_chipstate here — which drains the same queue
// the reader empties, discarding data frames while hunting (its own comment says it belongs
// at the END of a run); mid-run health must never compete with the reader (self-review).
// .unknown until the first reply arrives, and after that at most one poll interval stale.
pub fn (mut b VectorBus) health() BusHealth {
	h := if b.last_chip >= 0 { xl_chipstat_health(u8(b.last_chip)) } else { BusHealth.unknown }
	C.ct_vector_reqchip(b.port, b.mask) // reply lands in recv's capture on a later frame
	return h
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

// VectorMapping is one PHYSICAL channel and the application channel pointed at it, if any.
//
// THE PHYSICAL CHANNEL IS THE ROW, which is the whole difference from `vector_list`. That function
// answers "which of our application channels are usable", which is right for opening and useless
// for ASSIGNING: it cannot show hardware nobody has mapped yet, and it names channels without
// saying what they are. Choosing hardware means seeing the hardware.
pub struct VectorMapping {
pub:
	hw VectorChannel // device, transceiver, serial, live rate, CAN-FD capability
	// Our application channel mapped to this hardware, or 0 for none. `vector:${app}` is the
	// address it would be opened by.
	app int
	// Whether `app == 0` may be believed. False means some application channel could not be read,
	// so this row might already be owned by it — do not offer to assign a second channel to it.
	// Always true where `app > 0`: an owner we found is evidence in its own right.
	owner_known bool
}

// vector_app_slots asks the driver about every application channel, once.
//
// ONE SWEEP FEEDS EVERYTHING. The free-channel search, the ownership of each physical channel and
// "has this application been seen at all" are three questions about the same 64 answers, and they
// were three separate sweeps with three chances to disagree — one of which stopped at eight
// channels and so reported "nothing answered" for a bench configured on channel 9 and up. That is
// the mistake vector_list's own comment already records: sizing a sweep by what a bench plausibly
// has (codex #192 r3).
//
// THE FULL 1..64 RANGE, matching vector_app_channel and the shim's table, for the same reason.
// vector_app_slot asks about ONE application channel — the one an operator named. Cheaper than a
// sweep and, more to the point, an answer about the channel being written rather than an
// inference from the others (#192, option 3).
// confirm_absent re-asks when the answer was `absent`, and ONLY then.
//
// `absent` is the one verdict that rests on a GENERIC driver error — 255 is XL_ERROR, not a
// documented "no such channel" status — and it is also the only verdict that PERMITS a write. A
// single transient failure must therefore not be enough to authorize one (codex #192 r8).
//
// WHY NOT SIMPLY REFUSE 255, which is what r8 proposed: an unregistered channel answers 255 every
// time, and so does every channel of an application that does not exist yet. Refusing it refuses 57
// of 64 channels on this bench and ALL 64 on a fresh one — where creating the mapping is the entire
// purpose (#186). The feature would be unable to bootstrap itself.
//
// So the question is asked twice instead. A channel that is genuinely outside the application's list
// answers 255 consistently; a transient error, by definition, does not. Any second answer that
// DESCRIBES the channel wins, and all three of them (`taken`, `empty`, `unreadable`) are safer than
// `absent` — two refuse outright and the third permits for a reason that does not rest on a generic
// error. This narrows the window; it does not close it, and nothing vxlapi offers can. What stands
// behind it is that the ownership check now fails independently: both guards used to be broken by
// one misread, because both read the same slot.
// The decision itself is reconcile_absent, in vector_names.v where the tests can reach it; this is
// only the second question.
fn confirm_absent(app int, first AppSlot) AppSlot {
	if first != .absent {
		return first
	}
	return reconcile_absent(first, slot_of(appl_get_code(app)))
}

pub fn vector_app_slot(app int) AppSlot {
	if app < 1 || app > 64 {
		return .unreadable
	}
	return confirm_absent(app, slot_of(appl_get_code(app)))
}

pub fn vector_app_slots() []AppSlot {
	mut out := []AppSlot{cap: 64}
	for app in 1 .. 65 {
		out << confirm_absent(app, slot_of(appl_get_code(app)))
	}
	return out
}

// vector_mappings lists every channel the driver reports, each with the application channel — if
// any — pointing at it, and what is actually KNOWN about that.
//
// THE PHYSICAL CHANNEL IS THE ROW, which is the whole difference from `vector_list`. That function
// answers "which of our application channels are usable", which is right for opening and useless
// for ASSIGNING: it cannot show hardware nobody has mapped yet, and it names channels without
// saying what they are. Choosing hardware means seeing the hardware.
//
// A CHANNEL WE COULD NOT READ POISONS THE WHOLE SWEEP, deliberately. An unreadable channel may
// have been the owner of any of this hardware, and nothing in the answers says which — so every
// otherwise-unowned row is marked `owner_known: false` rather than reported as free. Folding the
// failure into "no owner" offers an Assign button for hardware that already has one, and taking it
// maps a SECOND application channel onto one physical wire: the alias destination_conflicts refuses
// a whole project for (#167), manufactured by the dialog meant to set the bench up.
//
// THE FLAG IS NEW IN R6 AND SO IS THE ABILITY TO CARRY IT. Until the shim separated "cannot answer"
// from "no such channel", 57 of 64 channels on an ordinary bench read as unreadable — poisoning
// every row, every time, which is unusable and is why this comment described a behaviour the code
// did not implement (codex #192 r6). Now only a genuine driver failure poisons, so the rule the
// comment always claimed can actually be enforced. `absent` and `empty` channels are known NOT to
// be owners, and cost nothing.
pub fn vector_mappings() []VectorMapping {
	hw := vector_channels()
	slots := vector_app_slots()
	mut owner := map[string]int{}
	mut known := true
	for i, s in slots {
		if s == .unreadable {
			// This one may own any row, and we cannot ask which.
			known = false
			continue
		}
		if s != .taken {
			continue
		}
		a, ok := vector_assignment(i + 1) or {
			// It said `taken` a moment ago and will not say what it points at now. Same problem.
			known = false
			continue
		}
		if ok {
			owner['${a.hw_type}:${a.hw_index}:${a.hw_channel}'] = i + 1
		}
	}
	mut out := []VectorMapping{}
	for c in hw {
		app := owner['${c.hw_type}:${c.hw_index}:${c.hw_channel}'] or { 0 }
		out << VectorMapping{
			hw:  c
			app: app
			// A row we DID find an owner for is known regardless: that owner is positive evidence,
			// and no unreadable channel can take it away.
			owner_known: known || app > 0
		}
	}
	return out
}

// vector_application_seen reports whether ANY application channel answered — evidence that the
// application exists, not proof that it does not.
//
// EVIDENCE, NOT A VERDICT, and the name carries the difference. `true` is proof: a channel
// answered, so the application is there. `false` is only "nothing answered" — which is what an
// absent application looks like AND what a driver that has stopped answering looks like. vxlapi
// documents no status that proves absence, and this will not invent one, so a caller must not turn
// `false` into "the application does not exist" (codex #192 r2).
//
// From the SAME sweep the rest uses, so it can no longer disagree with them about the range it
// covered (codex #192 r3).
//
// ONLY `empty` AND `taken` ARE EVIDENCE. Both mean the driver described a channel that belongs to
// this application, which cannot happen unless the application is registered. `absent` is the
// driver saying it has no such channel — true of 57 of 64 on a bench that is perfectly well set up,
// so it proves nothing either way. `unreadable` is silence. Since r6 this is informational only:
// nothing decides whether to WRITE from it any more (see assign_refusal).
pub fn vector_application_seen() !bool {
	if C.ct_vector_load() != 0 {
		return error('the Vector driver could not be asked about the application "blobly_net"')
	}
	for s in vector_app_slots() {
		if s == .empty || s == .taken {
			return true
		}
	}
	return false
}


// vector_list reports the application channels that have hardware assigned, for discovery.
// Returns [] when vxlapi64.dll is absent.
//
// It lists what is CONFIGURED, not what is plugged in — the XL library addresses application
// channels, and a VN1630A nobody has assigned yet appears here only once the operator has
// pointed a channel at it in Vector Hardware Configuration.
//
// THE PHYSICAL LIST IS vector_channels(), which is a different question and answers it from
// XLdriverConfig. This comment used to say that struct's layout was deliberately not reproduced;
// that stopped being true when hardware discovery landed, and there is no other source for
// "what is plugged in" (codex #188).
//
// The layout is reproduced in vector_shim.h with _Static_asserts on its size and offsets — but be
// clear what those prove. vxlapi.h is not included, so each one compares our transcribed struct
// against a constant transcribed from the SAME reading of the header: both sides are ours. They
// catch local drift, which is a field added, reordered or mis-sized after the fact, and that is
// what they are for. They do NOT catch a value transcribed wrongly to begin with, and they cannot
// notice an installed vxlapi64.dll whose ABI differs from 25.20.14 — either still reads the wrong
// fields, or past the end of the channel array, at runtime.
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
		state := C.ct_vector_present(u32(ch - 1))
		if state == 0 {
			continue
		}
		// LISTED EITHER WAY, and said which. A channel assigned to an adapter that is currently
		// unplugged is still assigned, and dropping it from this list told the operator to go
		// and create a mapping that already existed.
		note := if state == 2 { ' — assigned, hardware not present' } else { '' }
		out << Iface{
			name:    'Vector application channel ${ch}${note}'
			iface:   'vector:${ch}'
			kind:    'can'
			virtual: false
		}
	}
	return out
}
