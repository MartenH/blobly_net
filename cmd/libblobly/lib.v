// cmd/libblobly — the engine as a SHARED LIBRARY with a C ABI, for a host that is not V: a
// Python package through ctypes is the one it exists for (65 µs reactions measured in-process,
// against 950 µs over loopback TCP). The ABI is bb.h, the ONE statement of it, compiled in here
// and read by every host; this file is the thin V side of each call and holds no rule of its own.
//
//   v -enable-globals -prod -shared -o build/libblobly.so cmd/libblobly   (scripts/build_libblobly.sh)
//
// Over the merged blobly.headless (load / start / stop) and blobly.transport (a bus handle of the
// host's own). Nothing of UDS and nothing event-driven yet: those are the next PRs' seams.
//
// Strings handed to the host are V strings' bytes: kept in globals so the collector keeps them,
// and valid until the next call that replaces them (bb.h says so) — except the error text, which
// is a per-thread C buffer (host.h), so a worker's call cannot overwrite the driver thread's.
module main

#flag -DBB_FROM_V
#include "@VMODROOT/cmd/libblobly/bb.h"
#include "@VMODROOT/cmd/libblobly/host.h"

import sync
import v.vmod
import blobly.headless
import blobly.project
import blobly.transport

// per-thread error text and attached flag (host.h)
fn C.bb_err_set(&char)
fn C.bb_err_get() &char
fn C.bb_attached() int
fn C.bb_set_attached(int)

pub struct C.bb_frame {
pub mut:
	id   u32
	len  u8
	ext  u8
	fd   u8
	brs  u8
	data [64]u8
}

// the library calls itself what v.mod says, as the app does (cmd/blobly_net/version.v)
const lib_version = (vmod.decode(@VMOD_FILE) or { panic('v.mod unparsable: ${err}') }).version

const bb_ok = 0
const bb_err = -1
const bb_err_handle = -2
const bb_err_state = -3

// BusHandle is one bus the host opened. The table is keyed by an index that is never reused
// (`bb_next`), and a closed handle is DELETED from it, so its bus — an inproc queue is 8192
// frames — is the collector's again; held, 3000 open/close churns peaked at 2.4 GB and 73 s, let
// go 35 MB and 1.6 s (self-review).
// Under `bb_mu`, since bb.h lets send and recv run on an attached thread of their own while the
// driver thread opens and closes; the bus itself is used outside the lock, and a close under a
// blocked recv ends that recv with the bus's own `closed` error.
struct BusHandle {
mut:
	bus transport.Bus
}

__global (
	bb_mu      sync.Mutex
	bb_proj    project.Project
	bb_path    string
	bb_loaded  bool
	bb_run     &headless.Run = unsafe { nil }
	bb_names   []string // the C strings bb_channel_* handed out, kept alive here
	bb_handles map[int]&BusHandle
	bb_next    int
)

fn fail(code int, msg string) int {
	C.bb_err_set(&char(msg.str))
	return code
}

fn ok() int {
	C.bb_err_set(c'')
	return bb_ok
}

fn cstr(s string) &char {
	return &char(s.str)
}

@[export: 'bb_version']
pub fn bb_version() &char {
	return cstr(lib_version)
}

// bb_init: the V runtime (collector, globals) came up in the library's constructor when it was
// loaded, before any call; measured from a C host and a ctypes host (cmd/libblobly/smoke.*).
// Here so a host-side requirement has a place without changing the ABI.
@[export: 'bb_init']
pub fn bb_init() int {
	return ok()
}

// Boehm's registration of a thread it did not create (gc_attach.h)
struct C.bb_stack_base {
mut:
	mem_base voidptr
}

fn C.GC_get_stack_base(voidptr) int
fn C.GC_register_my_thread(voidptr) int
fn C.GC_unregister_my_thread() int

// bb_thread_attach: a thread the HOST created tells the collector about itself before its first
// call. Every V thread is born registered; a host's is not, and the first collection an
// allocation on it triggers is Boehm's `Collecting from unknown thread` abort — measured, from a
// C pthread and from a Python thread (cmd/libblobly/smoke.*). Registering a registered thread
// (the loading one, or twice) is GC_DUPLICATE: harmless, ok here, and NOT this call's to detach.
// The messages are literals: this thread is not registered yet, so nothing may allocate on it.
@[export: 'bb_thread_attach']
pub fn bb_thread_attach() int {
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
pub fn bb_thread_detach() int {
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
pub fn bb_load(path &char) int {
	if isnil(path) {
		return fail(bb_err, 'load: no path')
	}
	if !isnil(bb_run) {
		return fail(bb_err_state, 'a run is active; stop it before loading another project')
	}
	p := unsafe { cstring_to_vstring(path) }
	proj := headless.load(p, headless.Options{}) or { return fail(bb_err, err.msg()) }
	bb_proj = proj
	bb_path = p
	bb_loaded = true
	name_rows(proj)
	return ok()
}

// name_rows is the enabled rows' names and interfaces, as C strings that outlive the call.
fn name_rows(proj project.Project) {
	bb_names = []string{}
	for ch in proj.channels {
		if ch.enabled {
			bb_names << ch.name
			bb_names << ch.iface_with_bitrate()
		}
	}
}

@[export: 'bb_start']
pub fn bb_start() int {
	if !bb_loaded {
		return fail(bb_err_state, 'no project loaded')
	}
	if !isnil(bb_run) {
		return fail(bb_err_state, 'already started; stop first')
	}
	r := headless.start(bb_proj, bb_path, headless.Options{}) or {
		// headless's own state refusal (a previous run's loop still out past stop's bound)
		code := if err.msg() == headless.active_note { bb_err_state } else { bb_err }
		return fail(code, err.msg())
	}
	bb_run = r
	// as the RUN has them: start moves a hosted DoIP row onto a port this process could bind, and
	// the address a host dials must be that one (self-review: the smoke printed 13400 while the
	// entity listened on 30342)
	name_rows(r.proj)
	return ok()
}

@[export: 'bb_stop']
pub fn bb_stop() int {
	if isnil(bb_run) {
		return fail(bb_err_state, 'not started')
	}
	mut r := bb_run
	bb_run = unsafe { nil }
	r.stop()
	return ok()
}

@[export: 'bb_channel_count']
pub fn bb_channel_count() int {
	if !bb_loaded {
		return fail(bb_err_state, 'no project loaded')
	}
	ok()
	return bb_names.len / 2
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
pub fn bb_channel_name(i int) &char {
	return channel_str(i, 0)
}

@[export: 'bb_channel_iface']
pub fn bb_channel_iface(i int) &char {
	return channel_str(i, 1)
}

@[export: 'bb_bus_open']
pub fn bb_bus_open(iface &char) int {
	if isnil(iface) {
		return fail(bb_err, 'open: no interface')
	}
	name := unsafe { cstring_to_vstring(iface) }
	bus := transport.open(name) or { return fail(bb_err, '${name}: ${err.msg()}') }
	bb_mu.lock()
	h := bb_next
	bb_next++
	bb_handles[h] = &BusHandle{
		bus: bus
	}
	bb_mu.unlock()
	ok()
	return h
}

fn handle(h int) ?&BusHandle {
	bb_mu.lock()
	defer {
		bb_mu.unlock()
	}
	if hd := bb_handles[h] {
		return hd
	}
	return none
}

@[export: 'bb_bus_send']
pub fn bb_bus_send(h int, f &C.bb_frame) int {
	mut hd := handle(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
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
	hd.bus.send(transport.CanFrame{
		id:       f.id
		extended: f.ext != 0
		fd:       f.fd != 0
		brs:      f.brs != 0
		data:     data
	}) or { return fail(bb_err, 'send: ${err.msg()}') }
	return ok()
}

@[export: 'bb_bus_recv']
pub fn bb_bus_recv(h int, timeout_ms int, out &C.bb_frame) int {
	mut hd := handle(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	if isnil(out) {
		return fail(bb_err, 'recv: nowhere to put the frame')
	}
	fr := hd.bus.recv(timeout_ms) or {
		if err.msg() == 'timeout' {
			ok() // nothing in time is not an error
			return 1
		}
		return fail(bb_err, 'recv: ${err.msg()}')
	}
	// after the frame is OUT of V: a close from another thread ended this recv as an error above
	unsafe {
		out.id = fr.id
		out.len = u8(fr.data.len)
		out.ext = u8(fr.extended)
		out.fd = u8(fr.fd)
		out.brs = u8(fr.brs)
		for i in 0 .. 64 {
			out.data[i] = if i < fr.data.len { fr.data[i] } else { u8(0) }
		}
	}
	return ok()
}

@[export: 'bb_bus_health']
pub fn bb_bus_health(h int) int {
	mut hd := handle(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	ok()
	return int(hd.bus.health())
}

@[export: 'bb_bus_close']
pub fn bb_bus_close(h int) int {
	bb_mu.lock()
	mut hd := bb_handles[h] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no open bus handle ${h}')
	}
	bb_handles.delete(h)
	bb_mu.unlock()
	hd.bus.close()
	return ok()
}
