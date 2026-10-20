// cmd/libblobly — the engine as a SHARED LIBRARY with a C ABI, for a host that is not V: a
// Python package through ctypes is the one it exists for (65 µs reactions measured in-process,
// against 950 µs over loopback TCP). The ABI is bb.h, the ONE statement of it, compiled in here
// and read by every host; this file is the thin V side of each call and holds no rule of its own.
//
//   v -enable-globals -prod -shared -nocache -o build/libblobly.so cmd/libblobly
//   (scripts/build_libblobly.sh)
//
// Over the merged blobly.headless (load / start / stop) and blobly.transport (a bus handle of the
// host's own). Nothing of UDS and nothing event-driven yet: those are the next PRs' seams.
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

// the library calls itself what v.mod says, as the app does (cmd/blobly_net/version.v)
const lib_version = (vmod.decode(@VMOD_FILE) or { panic('v.mod unparsable: ${err}') }).version

const bb_ok = i32(0)
const bb_err = i32(-1)
const bb_err_handle = i32(-2)
const bb_err_state = i32(-3)

// how long one bus call inside bb_bus_recv waits before it looks at the handle's `closing` again:
// bounds how long a close waits for a receive on another thread
const recv_slice_ms = 20

// BusHandle is one bus the host opened. The table is keyed by an index that is never reused
// (`bb_next`), and a closed handle is DELETED from it, so its bus — an inproc queue is 8192
// frames — is the collector's again; held, 3000 open/close churns peaked at 2.4 GB and 73 s, let
// go 35 MB and 1.6 s (self-review).
// The table is under `bb_mu`, since bb.h lets send and recv run on an attached thread of their
// own while the driver thread opens and closes; the bus is used outside the lock, COUNTED
// (`users`), and closed only once nobody is inside it: a SocketCAN read blocked in recvmsg is not
// woken by a close from another thread, and a closed fd's number may be the next socket's (the
// served-connection double close on #477).
@[heap]
struct BusHandle {
mut:
	bus     transport.Bus
	users   i64 // calls inside `bus` now
	closing i64 // bb_bus_close has begun: a receive in progress ends at its next slice
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
pub fn bb_start() i32 {
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
pub fn bb_stop() i32 {
	if isnil(bb_run) {
		return fail(bb_err_state, 'not started')
	}
	mut r := bb_run
	bb_run = unsafe { nil }
	r.stop()
	return ok()
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

@[export: 'bb_bus_open']
pub fn bb_bus_open(iface &char) i32 {
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

// bb_bus_recv waits in slices of recv_slice_ms, so a close on another thread ends it at the next
// one; a negative timeout waits until a frame, or that close.
@[export: 'bb_bus_recv']
pub fn bb_bus_recv(h i32, timeout_ms i32, out &C.bb_frame) i32 {
	if isnil(out) {
		return fail(bb_err, 'recv: nowhere to put the frame')
	}
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	deadline := time.ticks() + i64(timeout_ms)
	mut fr := transport.CanFrame{}
	for {
		if stdatomic.load_i64(&hd.closing) != 0 {
			return fail(bb_err_handle, 'recv: the handle was closed')
		}
		mut slice := recv_slice_ms
		if timeout_ms >= 0 {
			left := deadline - time.ticks()
			slice = if left < recv_slice_ms {
				int(if left < 0 { 0 } else { left })
			} else {
				recv_slice_ms
			}
		}
		fr = hd.bus.recv(slice) or {
			if err.msg() == 'timeout' {
				if timeout_ms >= 0 && time.ticks() >= deadline {
					ok() // nothing in time is not an error
					return 1
				}
				continue
			}
			return fail(bb_err, 'recv: ${err.msg()}')
		}
		break
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

@[export: 'bb_bus_health']
pub fn bb_bus_health(h i32) i32 {
	mut hd := enter(h) or { return fail(bb_err_handle, 'no open bus handle ${h}') }
	defer {
		hd.leave()
	}
	ok()
	return i32(hd.bus.health())
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
