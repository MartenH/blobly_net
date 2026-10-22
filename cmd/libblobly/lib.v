// cmd/libblobly — the engine as a SHARED LIBRARY with a C ABI, for a host that is not V: a
// Python package through ctypes is the one it exists for (65 µs reactions measured in-process,
// against 950 µs over loopback TCP). The ABI is bb.h, the ONE statement of it, compiled in here
// and read by every host; this file is the thin V side of each call and holds no rule of its own.
//
//   v -enable-globals -prod -shared -nocache -o build/libblobly.so cmd/libblobly
//   (scripts/build_libblobly.sh)
//
// Over the merged blobly.headless (load / start / stop), blobly.transport (a bus handle of the
// host's own) and blobly.candb (the run's row databases: encode and decode through the functions
// the Lua prelude's bus.send_message and decode use). Nothing of UDS yet: that is a later PR's
// seam.
//
// EVERY INTEGER AT THE BOUNDARY IS i32. V3's `int` is 64 bits and C's is 32: an export taking
// `int` reads a C caller's -1 as 4294967295 (local codex review, measured), so bb.h's `int` is
// spelled `i32` here and nowhere else.
//
// Strings handed to the host are V strings' bytes: kept in globals so the collector keeps them,
// and valid until the next call that replaces them (bb.h says so) — except the error text, which
// is a per-thread C buffer (host.h), so a worker's call cannot overwrite the driver thread's.
module main

#flag -DBB_FROM_V
#include "@VMODROOT/cmd/libblobly/bb.h"
#include "@VMODROOT/cmd/libblobly/host.h"

import sync
import sync.stdatomic
import time
import v.vmod
import blobly.candb
import blobly.headless
import blobly.project
import blobly.transport

// per-thread error text and attached flag (host.h)
fn C.bb_err_set(&char)
fn C.bb_err_get() &char
fn C.bb_attached() i32
fn C.bb_set_attached(i32)

pub struct C.bb_frame {
pub mut:
	id   u32
	len  u8
	ext  u8
	fd   u8
	brs  u8
	rtr  u8
	esi  u8
	data [64]u8
}

pub struct C.bb_message {
pub mut:
	id      u32
	ext     u8
	j1939   u8
	dlc     i32
	signals i32
}

pub struct C.bb_signal {
pub mut:
	start_bit   i32
	length      i32
	big_endian  u8
	is_signed   u8
	multiplexor u8
	multiplexed u8
	mux_value   i32
	labels      i32
	factor      f64
	offset      f64
	minimum     f64
	maximum     f64
}

// the library calls itself what v.mod says, as the app does (cmd/blobly_net/version.v)
const lib_version = (vmod.decode(@VMOD_FILE) or { panic('v.mod unparsable: ${err}') }).version

// the codes as bb.h defines them: read from the header, never restated, so the two cannot drift
const bb_ok = i32(0)
const bb_err = i32(C.BB_ERR)
const bb_err_handle = i32(C.BB_ERR_HANDLE)
const bb_err_state = i32(C.BB_ERR_STATE)
const bb_none = i32(C.BB_NONE)
const bb_spent = i32(C.BB_SPENT)
const bb_releasing = i32(C.BB_RELEASING)

// how long one bus call inside bb_bus_recv waits before it looks at the handle's `closing` again:
// bounds how long a close waits for a receive on another thread
const recv_slice_ms = 20

// BusHandle is one bus the host opened. The table is keyed by an index that is never reused
// (`bb_next`), and a closed handle is DELETED from it, so its bus — an inproc queue is 8192
// frames — is the collector's again; held, 3000 open/close churns peaked at 2.4 GB and 73 s, let
// go 35 MB and 1.6 s (self-review).
// The table is under `bb_mu`, since a handle's thread may be an attached one of its own while the
// driver thread opens and closes others (bb.h: one thread per handle, and a close from another);
// the bus is used outside the lock, COUNTED (`users`), and closed only once nobody is inside it: a
// SocketCAN read blocked in recvmsg is not woken by a close from another thread, and a closed
// fd's number may be the next socket's (the served-connection double close on #477).
@[heap]
struct BusHandle {
mut:
	bus     transport.Bus
	users   i64 // calls inside `bus` now
	closing i64 // bb_bus_close has begun: a receive in progress ends at its next slice
	// asks `closing`, for transport.recv_sliced: built once at open, not per receive
	stop fn () bool = unsafe { nil }
}

__global (
	bb_mu       sync.Mutex
	bb_proj     project.Project
	bb_path     string
	bb_loaded   bool
	bb_run      &headless.Run = unsafe { nil }
	bb_names    []string // the C strings bb_channel_* handed out, kept alive here
	bb_rows     []project.Channel // the enabled rows they name, for bb_channel_kind / _health_source
	bb_handles  map[int]&BusHandle
	bb_next     int
	// the run's row databases, aligned with bb_rows, under bb_mu: a database call may come from
	// any thread, so a stop on the driver's replaces the array rather than writing into it
	bb_dbs      []candb.Database
	bb_dbs_live bool
)

fn fail(code i32, msg string) i32 {
	C.bb_err_set(&char(msg.str))
	return code
}

fn ok() i32 {
	C.bb_err_set(c'')
	return bb_ok
}

fn cstr(s string) &char {
	return &char(s.str)
}

@[export: 'bb_version']
pub fn bb_version() &char {
	ok()
	return cstr(lib_version)
}

// bb_init: the V runtime (collector, globals) came up in the library's constructor when it was
// loaded, before any call; measured from a C host and a ctypes host (cmd/libblobly/smoke.*).
// Here so a host-side requirement has a place without changing the ABI.
@[export: 'bb_init']
pub fn bb_init() i32 {
	return ok()
}

// Boehm's registration of a thread it did not create (host.h). V's own C.GC_stack_base came out
// an incomplete type in this library's C under V3's module cache (a -shared build that cache
// cannot complete at all now, so not isolated further); the one-field struct is ours instead.
struct C.bb_stack_base {
mut:
	mem_base voidptr
}

fn C.GC_get_stack_base(voidptr) i32
fn C.GC_register_my_thread(voidptr) i32
fn C.GC_unregister_my_thread() i32

// bb_thread_attach: a thread the HOST created tells the collector about itself before its first
// call. Every V thread is born registered; a host's is not, and the first collection an
// allocation on it triggers is Boehm's `Collecting from unknown thread` abort — measured, from a
// C pthread and from a Python thread (cmd/libblobly/smoke.*). Registering a registered thread
// (the loading one, or twice) is GC_DUPLICATE: harmless, ok here, and NOT this call's to detach.
// The messages are literals: this thread is not registered yet, so nothing may allocate on it.
@[export: 'bb_thread_attach']
pub fn bb_thread_attach() i32 {
	mut sb := C.bb_stack_base{}
	if C.GC_get_stack_base(&sb) != 0 {
		return fail(bb_err, 'thread_attach: the collector cannot find this stack')
	}
	rc := C.GC_register_my_thread(&sb)
	if rc == 0 {
		C.bb_set_attached(1)
	} else if rc != 1 {
		return fail(bb_err, 'thread_attach: the collector refused this thread')
	}
	return ok()
}

// bb_thread_detach: the attached thread is about to end; the collector stops scanning its stack.
// Only a thread THIS library attached: GC_unregister_my_thread would delete the loading thread's
// record as readily (measured: a core dump on the next call).
@[export: 'bb_thread_detach']
pub fn bb_thread_detach() i32 {
	if C.bb_attached() == 0 {
		return fail(bb_err, 'thread_detach: this thread was not attached by bb_thread_attach')
	}
	C.GC_unregister_my_thread()
	C.bb_set_attached(0)
	return ok()
}

@[export: 'bb_last_error']
pub fn bb_last_error() &char {
	return C.bb_err_get()
}

@[export: 'bb_load']
pub fn bb_load(path &char) i32 {
	if isnil(path) {
		return fail(bb_err, 'load: no path')
	}
	if !isnil(bb_run) {
		return fail(bb_err_state, 'a run is active; stop it before loading another project')
	}
	p := unsafe { cstring_to_vstring(path) }
	proj := headless.load(p, headless.Options{}) or { return fail(bb_err, err.msg()) }
	// a name or an interface the host would receive cut at its first NUL names another row, or
	// another bus (an inproc name is free text)
	for ch in proj.channels {
		if ch.enabled && (ch.name.contains_u8(0) || ch.iface_with_bitrate().contains_u8(0)) {
			return fail(bb_err, 'load: channel "${ch.name.replace('\0', '\\0')}" has a NUL in its name or interface, which a C string cannot carry')
		}
	}
	bb_proj = proj
	bb_path = p
	bb_loaded = true
	name_rows(proj.channels.filter(it.enabled))
	return ok()
}

// name_rows is the enabled rows and their names and interfaces, as C strings that outlive the
// call.
fn name_rows(rows []project.Channel) {
	bb_names = []string{}
	for ch in rows {
		bb_names << ch.name
		bb_names << ch.iface_with_bitrate()
	}
	bb_rows = rows.clone()
}

@[export: 'bb_start']
pub fn bb_start() i32 {
	if !bb_loaded {
		return fail(bb_err_state, 'no project loaded')
	}
	if !isnil(bb_run) {
		return fail(bb_err_state, 'already started; stop first')
	}
	r := headless.start(bb_proj, bb_path, headless.Options{}) or {
		// headless's own state refusal: with no run of ours, a previous run's loop is still out
		// past its stop's bound
		if err.msg() == headless.active_note {
			return fail(bb_err_state, 'a previous run is still releasing its wires; wait until it has (bb_wait_released), then start')
		}
		return fail(bb_err, err.msg())
	}
	bb_run = r
	// as the RUN has them: start moves a hosted DoIP row onto a port this process could bind, and
	// the address a host dials must be that one (self-review: the smoke printed 13400 while the
	// entity listened on 30342). The rows and their databases from one array, so a row's index
	// is its databases' by construction.
	name_rows(r.chans.map(it.cfg))
	bb_mu.lock()
	bb_dbs = r.chans.map(it.db)
	bb_dbs_live = true
	bb_mu.unlock()
	return ok()
}

@[export: 'bb_stop']
pub fn bb_stop() i32 {
	if isnil(bb_run) {
		return fail(bb_err_state, 'not started')
	}
	mut r := bb_run
	bb_run = unsafe { nil }
	bb_mu.lock()
	bb_dbs = []candb.Database{}
	bb_dbs_live = false
	bb_mu.unlock()
	r.stop()
	// the rows as the project says again: a moved DoIP port was the stopped run's
	name_rows(bb_proj.channels.filter(it.enabled))
	if !headless.released() {
		ok()
		return bb_releasing
	}
	return ok()
}

@[export: 'bb_wait_released']
pub fn bb_wait_released(timeout_ms i32) i32 {
	if headless.wait_released(int(timeout_ms)) {
		return ok()
	}
	ok()
	return bb_releasing
}

@[export: 'bb_channel_count']
pub fn bb_channel_count() i32 {
	if !bb_loaded {
		return fail(bb_err_state, 'no project loaded')
	}
	ok()
	return i32(bb_names.len / 2)
}

fn channel_str(i int, which int) &char {
	if !bb_loaded || i < 0 || i * 2 + which >= bb_names.len {
		fail(bb_err, 'no channel ${i}')
		return c''
	}
	ok()
	return cstr(bb_names[i * 2 + which])
}

@[export: 'bb_channel_name']
pub fn bb_channel_name(i i32) &char {
	return channel_str(int(i), 0)
}

@[export: 'bb_channel_iface']
pub fn bb_channel_iface(i i32) &char {
	return channel_str(int(i), 1)
}

fn row(i i32) ?project.Channel {
	if !bb_loaded || i < 0 || int(i) >= bb_rows.len {
		return none
	}
	return bb_rows[int(i)]
}

@[export: 'bb_channel_kind']
pub fn bb_channel_kind(i i32) i32 {
	ch := row(i) or { return fail(bb_err, 'no channel ${i}') }
	ok()
	if ch.is_doip() {
		return i32(C.BB_KIND_DOIP)
	}
	if ch.is_someip() {
		return i32(C.BB_KIND_SOMEIP)
	}
	return i32(C.BB_KIND_CAN)
}

@[export: 'bb_channel_health_source']
pub fn bb_channel_health_source(i i32) i32 {
	ch := row(i) or { return fail(bb_err, 'no channel ${i}') }
	ok()
	if ch.is_eth() {
		return i32(C.BB_HEALTH_SOURCE_NONE)
	}
	return match transport.health_source(ch.iface_with_bitrate()) {
		.no_controller { i32(C.BB_HEALTH_SOURCE_NONE) }
		.polled { i32(C.BB_HEALTH_SOURCE_POLLED) }
		.needs_reader { i32(C.BB_HEALTH_SOURCE_NEEDS_READER) }
	}
}

@[export: 'bb_bus_open']
pub fn bb_bus_open(iface &char) i32 {
	if isnil(iface) {
		return fail(bb_err, 'open: no interface')
	}
	name := unsafe { cstring_to_vstring(iface) }
	// the rules the model uses — the interface's scheme, and a row's own type: on Linux a DoIP or
	// SOME/IP endpoint would fall through to SocketCAN and fail as a missing device
	if project.iface_is_eth(name) || (bb_loaded && bb_rows.any(it.is_eth()
		&& it.iface_with_bitrate() == name)) {
		return fail(bb_err, 'open: ${name} is a DoIP or SOME/IP endpoint, which carries no CAN frames')
	}
	bus := transport.open(name) or { return fail(bb_err, '${name}: ${err.msg()}') }
	mut hd := &BusHandle{
		bus: bus
	}
	closing := &hd.closing
	hd.stop = fn [closing] () bool {
		return stdatomic.load_i64(closing) != 0
	}
	bb_mu.lock()
	h := bb_next
	bb_next++
	bb_handles[h] = hd
	bb_mu.unlock()
	ok()
	return i32(h)
}

// enter is the open handle `h`, counted as in use until its `leave`; none for a closed or
// unknown one, or one being closed.
fn enter(h i32) ?&BusHandle {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if mut hd := bb_handles[int(h)] {
		stdatomic.add_i64(&hd.users, 1)
		return hd
	}
	return none
}

fn (mut hd BusHandle) leave() {
	stdatomic.add_i64(&hd.users, -1)
}

@[export: 'bb_bus_send']
pub fn bb_bus_send(h i32, f &C.bb_frame) i32 {
	if isnil(f) {
		return fail(bb_err, 'send: no frame')
	}
	n := int(f.len)
	if n > 64 {
		return fail(bb_err, 'send: a payload is at most 64 bytes, not ${n}')
	}
	mut data := []u8{len: n}
	for i in 0 .. n {
		data[i] = f.data[i]
	}
	// the flags as stated; which frames a controller could send is the transport's to refuse
	frame := transport.CanFrame{
		id:       f.id
		extended: f.ext != 0
		fd:       f.fd != 0
		brs:      f.brs != 0
		rtr:      f.rtr != 0
		esi:      f.esi != 0
		data:     data
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	hd.bus.send(frame) or { return fail(bb_err, 'send: ${err.msg()}') }
	return ok()
}

// bb_bus_recv waits in slices of recv_slice_ms (transport.recv_sliced, the rule isotp's stoppable
// receive uses), so a close on another thread ends it at the next one; a negative timeout waits
// until a frame, or that close; zero is one look (Bus.recv's recv(0) contract).
@[export: 'bb_bus_recv']
pub fn bb_bus_recv(h i32, timeout_ms i32, out &C.bb_frame) i32 {
	if isnil(out) {
		return fail(bb_err, 'recv: nowhere to put the frame')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	if stdatomic.load_i64(&hd.closing) != 0 {
		return fail(bb_err_handle, 'recv: the handle was closed')
	}
	fr := transport.recv_sliced(mut hd.bus, int(timeout_ms), recv_slice_ms, hd.stop) or {
		return recv_nothing(err)
	}
	// a frame bb_frame cannot carry is refused whole: a truncated payload published with its
	// real length is one a C host reads past the end of
	if fr.data.len > 64 {
		return fail(bb_err, 'recv: a frame of ${fr.data.len} bytes does not fit bb_frame (64 at most)')
	}
	unsafe {
		out.id = fr.id
		out.len = u8(fr.data.len)
		out.ext = u8(fr.extended)
		out.fd = u8(fr.fd)
		out.brs = u8(fr.brs)
		out.rtr = u8(fr.rtr)
		out.esi = u8(fr.esi)
		for i in 0 .. 64 {
			out.data[i] = if i < fr.data.len { fr.data[i] } else { u8(0) }
		}
	}
	return ok()
}

// recv_nothing is what bb_bus_recv answers for a receive that brought no frame.
fn recv_nothing(err IError) i32 {
	if err.code() == transport.sliced_stop_code {
		return fail(bb_err_handle, 'recv: the handle was closed')
	}
	if transport.look_was_spent(err) {
		ok()
		return bb_spent
	}
	if err.msg() == 'timeout' {
		ok() // nothing in time is not an error
		return bb_none
	}
	return fail(bb_err, 'recv: ${err.msg()}')
}

@[export: 'bb_bus_health']
pub fn bb_bus_health(h i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	ok()
	return health_code(hd.bus.health())
}

// health_code is bb.h's enum bb_health for a rung, by NAME: a variant added to transport.BusHealth
// fails this match, and one reordered there cannot shift what a host reads.
fn health_code(h transport.BusHealth) i32 {
	return match h {
		.unknown { i32(C.BB_HEALTH_UNKNOWN) }
		.ok { i32(C.BB_HEALTH_OK) }
		.warning { i32(C.BB_HEALTH_WARNING) }
		.error_passive { i32(C.BB_HEALTH_ERROR_PASSIVE) }
		.bus_off { i32(C.BB_HEALTH_BUS_OFF) }
	}
}

// bb_bus_close: out of the table at once, so no new call reaches it; closed once the calls
// already inside it have left — a receive within one slice.
@[export: 'bb_bus_close']
pub fn bb_bus_close(h i32) i32 {
	bb_mu.lock()
	mut hd := bb_handles[int(h)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no open bus handle ${h}')
	}
	bb_handles.delete(int(h))
	bb_mu.unlock()
	stdatomic.store_i64(&hd.closing, 1)
	for stdatomic.load_i64(&hd.users) > 0 {
		time.sleep(time.millisecond)
	}
	hd.bus.close()
	return ok()
}

// refused is a lookup's error as a bb.h answer: its own code where it carries one of bb.h's.
fn refused(err IError) i32 {
	return fail(if err.code() < 0 { i32(err.code()) } else { bb_err }, err.msg())
}

// run_db is row `row`'s databases as the run loaded them.
fn run_db(row i32) !candb.Database {
	bb_mu.lock()
	live := bb_dbs_live
	dbs := bb_dbs
	bb_mu.unlock()
	if !live {
		return error_with_code("not started: a row's databases are the run's, from bb_start until bb_stop",
			int(bb_err_state))
	}
	if row < 0 || int(row) >= dbs.len {
		return error('no channel ${row}')
	}
	return dbs[int(row)]
}

fn message(row i32, m i32) !candb.Message {
	db := run_db(row)!
	if m < 0 || int(m) >= db.messages.len {
		return error('channel ${row} has no message ${m} (it has ${db.messages.len})')
	}
	return db.messages[int(m)]
}

fn signal(row i32, m i32, s i32) !candb.Signal {
	msg := message(row, m)!
	if s < 0 || int(s) >= msg.signals.len {
		return error('${msg.name} has no signal ${s} (it has ${msg.signals.len})')
	}
	return msg.signals[int(s)]
}

// put copies `s` into the host's buffer of `cap` bytes, its NUL included, and answers the whole
// length: one at or past cap was cut.
fn put(s string, buf &char, cap i32) i32 {
	if cap < 0 {
		return fail(bb_err, 'a buffer of ${cap} bytes')
	}
	if cap > 0 {
		if isnil(buf) {
			return fail(bb_err, 'no buffer for its ${cap} bytes')
		}
		n := if s.len < int(cap) { s.len } else { int(cap) - 1 }
		unsafe {
			vmemcpy(buf, s.str, n)
			buf[n] = 0
		}
	}
	ok()
	return i32(s.len)
}

@[export: 'bb_message_count']
pub fn bb_message_count(row i32) i32 {
	db := run_db(row) or { return refused(err) }
	ok()
	return i32(db.messages.len)
}

@[export: 'bb_message_info']
pub fn bb_message_info(row i32, m i32, out &C.bb_message) i32 {
	if isnil(out) {
		return fail(bb_err, 'message_info: nowhere to put it')
	}
	msg := message(row, m) or { return refused(err) }
	unsafe {
		out.id = msg.id
		out.ext = u8(msg.ext)
		out.j1939 = u8(msg.j1939)
		out.dlc = i32(msg.dlc)
		out.signals = i32(msg.signals.len)
	}
	return ok()
}

@[export: 'bb_message_name']
pub fn bb_message_name(row i32, m i32, buf &char, cap i32) i32 {
	msg := message(row, m) or { return refused(err) }
	return put(msg.name, buf, cap)
}

@[export: 'bb_signal_info']
pub fn bb_signal_info(row i32, m i32, s i32, out &C.bb_signal) i32 {
	if isnil(out) {
		return fail(bb_err, 'signal_info: nowhere to put it')
	}
	sig := signal(row, m, s) or { return refused(err) }
	unsafe {
		out.start_bit = i32(sig.start_bit)
		out.length = i32(sig.length)
		out.big_endian = u8(sig.byte_order == .big_endian)
		out.is_signed = u8(sig.is_signed)
		out.multiplexor = u8(sig.is_multiplexor)
		out.multiplexed = u8(sig.is_multiplexed)
		out.mux_value = i32(sig.multiplexor_value)
		out.labels = i32(sig.values.len)
		out.factor = sig.factor
		out.offset = sig.offset
		out.minimum = sig.minimum
		out.maximum = sig.maximum
	}
	return ok()
}

@[export: 'bb_signal_name']
pub fn bb_signal_name(row i32, m i32, s i32, buf &char, cap i32) i32 {
	sig := signal(row, m, s) or { return refused(err) }
	return put(sig.name, buf, cap)
}

@[export: 'bb_signal_unit']
pub fn bb_signal_unit(row i32, m i32, s i32, buf &char, cap i32) i32 {
	sig := signal(row, m, s) or { return refused(err) }
	return put(sig.unit, buf, cap)
}

// bb_signal_label: the value table in the database's order, each entry as the physical value it
// names (phys_from_raw of its raw key, as decode reads that raw value).
@[export: 'bb_signal_label']
pub fn bb_signal_label(row i32, m i32, s i32, k i32, value &f64, buf &char, cap i32) i32 {
	if isnil(value) {
		return fail(bb_err, 'signal_label: nowhere to put the value')
	}
	sig := signal(row, m, s) or { return refused(err) }
	keys := sig.values.keys()
	if k < 0 || int(k) >= keys.len {
		return fail(bb_err, '${sig.name} has no label ${k} (it has ${keys.len})')
	}
	raw := keys[int(k)]
	unsafe {
		*value = sig.phys_from_raw(raw)
	}
	return put(sig.values[raw], buf, cap)
}

// bb_encode is bus.send_message's encoding (the Lua prelude): the message's template, then each
// named signal through Signal.encode.
@[export: 'bb_encode']
pub fn bb_encode(row i32, m i32, n i32, signals &&char, values &f64, out &C.bb_frame) i32 {
	if isnil(out) {
		return fail(bb_err, 'encode: nowhere to put the frame')
	}
	if n < 0 || (n > 0 && (isnil(signals) || isnil(values))) {
		return fail(bb_err, 'encode: ${n} signals, and no arrays of them')
	}
	msg := message(row, m) or { return refused(err) }
	if msg.dlc > 64 {
		return fail(bb_err, 'encode: ${msg.name} has a DLC of ${msg.dlc}, past what bb_frame carries (64)')
	}
	mut data := msg.template()
	for i in 0 .. int(n) {
		p := unsafe { signals[i] }
		if isnil(p) {
			return fail(bb_err, 'encode: signal name ${i} is NULL')
		}
		name := unsafe { cstring_to_vstring(p) }
		sig := msg.signal_named(name) or {
			return fail(bb_err, 'unknown signal "${name}" in ${msg.name}')
		}
		sig.encode(mut data, unsafe { values[i] })
	}
	unsafe {
		out.id = msg.id
		out.len = u8(data.len)
		out.ext = u8(msg.ext)
		out.fd = 0
		out.brs = 0
		out.rtr = 0
		out.esi = 0
		for i in 0 .. 64 {
			out.data[i] = if i < data.len { data[i] } else { u8(0) }
		}
	}
	return ok()
}

// bb_decode is the Lua prelude's decode: the message by Database.frame_index (lookup_frame's
// rule), each signal through Signal.physical, the ones the frame carries by Message.carried.
@[export: 'bb_decode']
pub fn bb_decode(row i32, f &C.bb_frame, message &i32, values &f64, active &u8, cap i32) i32 {
	if isnil(f) || isnil(message) {
		return fail(bb_err, 'decode: no frame, or nowhere to put its message')
	}
	if cap < 0 || (cap > 0 && (isnil(values) || isnil(active))) {
		return fail(bb_err, 'decode: arrays of ${cap}, and no arrays')
	}
	db := run_db(row) or { return refused(err) }
	if f.rtr != 0 {
		ok() // a remote frame carries no data to decode
		return bb_none
	}
	n := int(f.len)
	if n > 64 {
		return fail(bb_err, 'decode: a payload is at most 64 bytes, not ${n}')
	}
	i := db.frame_index(f.id, f.ext != 0) or {
		ok()
		return bb_none
	}
	msg := db.messages[i]
	unsafe {
		*message = i32(i)
	}
	if msg.signals.len > int(cap) {
		return fail(bb_err, 'decode: ${msg.name} has ${msg.signals.len} signals, and the arrays hold ${cap}')
	}
	mut data := []u8{len: n}
	for k in 0 .. n {
		data[k] = f.data[k]
	}
	on := msg.carried(data)
	for k, sig in msg.signals {
		unsafe {
			active[k] = u8(on[k])
			values[k] = if on[k] { sig.physical(data) } else { 0.0 }
		}
	}
	return ok()
}
