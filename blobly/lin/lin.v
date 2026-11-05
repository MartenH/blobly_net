// lin — the LIN bus, contained: its own frame, its own Bus interface, its own backends. It
// borrows only transport's general pieces (BusDiagnostics, CarrierGone) and is never a CAN row.
module lin

import time
import blobly.transport

// Errs is what went wrong with a frame, as a set.
@[flag]
pub enum Errs {
	sync        // the byte after the break was not 0x55
	parity      // the PID's parity bits were wrong
	checksum    // the checksum did not match the data
	framing     // a byte was read with a framing error
	short       // fewer bytes than the frame's length
	no_response // a header nobody answered
	collision   // this handle's response lost arbitration to another publisher's
	bit         // a publisher read back a bit other than the one it sent
	long        // more bytes than the frame's length
}

const err_names = ['sync', 'parity', 'checksum', 'framing', 'short', 'no_response', 'collision',
	'bit', 'long']

// names is each error in the set, in declaration order.
pub fn (e Errs) names() []string {
	mut out := []string{}
	for i, name in err_names {
		if u32(e) & (u32(1) << i) != 0 {
			out << name
		}
	}
	return out
}

// Event is what a record is: a frame, or a bus event.
pub enum Event {
	frame
	wakeup // a wakeup pulse
	sleep  // the go-to-sleep command (a MasterReq whose first byte is 0x00)
}

// Src is who put a frame's last part on the wire — its response, or the header when nobody
// answered — as the trace attributes it.
pub enum Src {
	remote // a node outside this app
	sim    // a simulated node of this app
	tester // the tester itself
}

pub struct Frame {
pub mut:
	id  u8
	pid u8
	// data is the response's data bytes; for a response cut short, every byte read.
	data []u8
	// raw is the bytes actually read after the PID, the checksum included.
	raw      []u8
	checksum u8
	model    Model
	errs     Errs
	event    Event
	// ours: this handle published the response (or sent the event).
	ours bool
	// header: this handle sent the header.
	header    bool
	src       Src
	t_ns      i64
	hw_ns     i64
	hw_domain string
}

pub enum Role {
	master
	slave
	monitor
}

pub fn (r Role) str() string {
	return match r {
		.master { 'master' }
		.slave { 'slave' }
		.monitor { 'monitor' }
	}
}

// Clock is the time a backend stamps its frames with, in nanoseconds on one monotonic scale.
pub interface Clock {
	now_ns() i64
}

// MonoClock is the host's monotonic clock.
pub struct MonoClock {}

pub fn (c MonoClock) now_ns() i64 {
	return i64(time.sys_mono_now())
}

pub struct Config {
pub:
	role Role
	baud int = 19200
	// src is what this handle's responses and events are, as the trace attributes them: .sim for
	// a simulated node, .tester for the tester, .remote for a stand-in for a node outside this app.
	src Src
	// nad is this node's diagnostic address; a SlaveResp entry answers only a MasterReq naming
	// it (or broadcast 0x7F). 0 is none; 0x7E and 0x7F are refused.
	nad u8
	// clock stamps frames; on inproc, the clock of the handle that created the hub.
	clock Clock = MonoClock{}
}

// Dir is a handle's part in a frame.
pub enum Dir {
	publish   // this handle answers the frame's header
	subscribe // this handle reads it (its length and model are known)
	ignore    // this handle has no part in it
}

// Fault is a response deliberately made wrong.
pub enum Fault {
	none
	bad_checksum // the checksum inverted
	silent       // no response, as if the entry were absent
	short        // the response cut after its first data byte
}

pub struct Entry {
pub:
	id    u8
	dir   Dir
	len   int
	model Model = .enhanced
	data  []u8
	// inject is a fault applied to every response the entry makes.
	inject Fault
	// one_shot entries are consumed by the header that uses them. A SlaveResp (0x3D) entry is
	// one-shot always.
	one_shot bool
}

pub enum State {
	active
	sleep
	short // the bus is shorted (hardware only)
}

pub struct Status {
pub:
	state State
	// schedule is the schedule a device runs itself; '' where the host schedules.
	schedule string
	// last_id is the id of the last header, -1 before the first.
	last_id int = -1
}

// RoleRefused is a call this handle's role may not make: every control call on a monitor,
// header and sleep on a slave. Nothing reached the bus.
pub struct RoleRefused {
	Error
pub:
	role Role
	call string
}

pub fn (e RoleRefused) msg() string {
	return 'lin: ${e.call} refused: this handle is a ${e.role}'
}

// Timeout is a receive that found no frame in its time; a closed bus is transport.CarrierGone.
pub struct Timeout {
	Error
}

pub fn (e Timeout) msg() string {
	return 'timeout'
}

// Bus is one handle on a LIN bus. Every handle receives every frame on the bus, its own
// included (marked `ours` / `header`). Configuring calls (set_entry, update) and the bus calls
// may come from a thread other than recv's; recv itself is one thread's. Entries belong to the
// handle that set them and are dropped when it closes.
pub interface Bus {
	// set_entry states this handle's part in a frame, replacing any earlier entry for its id.
mut:
	set_entry(e Entry) !
	// update replaces the data of this handle's publish entry for an id.
	update(id u8, data []u8) !
	// header sends a frame header (master only).
	header(id u8) !
	// wakeup sends a wakeup pulse.
	wakeup() !
	// sleep sends the go-to-sleep command (master only).
	sleep() !
	// recv returns the next frame within timeout_ms (0 a look, < 0 for ever): Timeout when none
	// came, transport.CarrierGone once the handle is closed.
	recv(timeout_ms int) !Frame
	status() Status
	diagnostics() transport.BusDiagnostics
	close()
}

// open opens a handle on the bus an address names. v1 knows `inproc:<name>`.
pub fn open(address string, cfg Config) !Bus {
	if address.starts_with('inproc:') {
		name := address[7..]
		if name == '' {
			return error('lin: `${address}` names no bus — write inproc:<name>')
		}
		return open_inproc(name, cfg)!
	}
	scheme := if address.contains(':') { address.all_before(':') } else { address }
	return error('lin: cannot open `${address}`: scheme `${scheme}` is not supported — this build opens inproc:<name>')
}

fn check_config(cfg Config) ! {
	if cfg.baud < 1000 || cfg.baud > 20000 {
		return error("lin: baud ${cfg.baud} is outside LIN's 1000..20000")
	}
	if cfg.nad == broadcast_nad {
		return error("lin: nad 0x7F is the broadcast address, not a node's")
	}
	if cfg.nad == functional_nad {
		return error("lin: nad 0x7E is the functional address, not a node's")
	}
}

fn check_id(id u8) ! {
	if id > max_id {
		return error('lin: id 0x${id:02X} is above 0x3F')
	}
}

// check_entry is the rule every backend holds an entry to.
fn check_entry(e Entry) ! {
	check_id(e.id)!
	if e.dir == .ignore {
		return
	}
	if e.len < 1 || e.len > max_data {
		return error('lin: entry 0x${e.id:02X} length ${e.len} is outside 1..8')
	}
	if (e.id == master_req || e.id == slave_resp) && e.len != max_data {
		return error('lin: entry 0x${e.id:02X} length ${e.len}: MasterReq and SlaveResp carry 8 data bytes')
	}
	if e.dir == .publish && e.data.len != e.len {
		return error('lin: entry 0x${e.id:02X} has ${e.data.len} data bytes for length ${e.len}')
	}
}
