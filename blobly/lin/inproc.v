// inproc — a driver-free in-process LIN bus. Handles attach to a named hub in a process-global
// registry; the master's header is resolved against every attached handle's entries, and the
// outcome is delivered to every handle, its own included. Requires `-enable-globals`.
module lin

import sync.stdatomic
import time
import blobly.transport

const inproc_queue_cap = 4096 // frames buffered per handle before drops

struct LinHub {
mut:
	handles []&InprocBus
	master  u32 // the master handle's id, 0 for none
	baud    int
	clock   Clock
	state   State
	last_id int = -1
}

struct LinRegistry {
mut:
	hubs    map[string]&LinHub
	next_id u32
}

__global (
	lin_inproc_reg shared LinRegistry
)

@[heap]
pub struct InprocBus {
mut:
	name    string
	id      u32
	cfg     Config
	queue   chan Frame
	dropped u64
	closed  u64 // 1 once closed
	// entries and armed are guarded by the registry lock.
	entries map[u8]Entry
	// armed: the last MasterReq addressed this handle's NAD, so its SlaveResp entry may answer.
	armed bool
}

// open_inproc attaches a handle to the named in-process LIN bus, creating the bus on first use
// with this handle's clock and baud. A second master, or a baud other than the bus's, is refused.
pub fn open_inproc(name string, cfg Config) !&InprocBus {
	check_config(cfg)!
	mut b := &InprocBus{
		name:  name
		cfg:   cfg
		queue: chan Frame{cap: inproc_queue_cap}
	}
	lock lin_inproc_reg {
		mut hub := lin_inproc_reg.hubs[name] or {
			h := &LinHub{
				baud:  cfg.baud
				clock: cfg.clock
			}
			lin_inproc_reg.hubs[name] = h
			h
		}
		if hub.baud != cfg.baud {
			return error('lin inproc:${name} runs at ${hub.baud} baud, not ${cfg.baud}')
		}
		if cfg.role == .master && hub.master != 0 {
			return error('lin inproc:${name} already has a master')
		}
		lin_inproc_reg.next_id++
		b.id = lin_inproc_reg.next_id
		if cfg.role == .master {
			hub.master = b.id
		}
		hub.handles << b
	}
	return b
}

fn (b &InprocBus) gone() IError {
	return transport.carrier_gone('lin inproc:${b.name}: handle is closed')
}

fn (b &InprocBus) is_closed() bool {
	return stdatomic.load_u64(&b.closed) != 0
}

// usable refuses a call this role may not make. Whether the handle is closed is asked under the
// registry lock, where close() sets it, so nothing reaches the bus after close() returns.
fn (b &InprocBus) usable(call string, master_only bool) ! {
	if b.cfg.role == .monitor || (master_only && b.cfg.role != .master) {
		return RoleRefused{
			role: b.cfg.role
			call: call
		}
	}
}

pub fn (mut b InprocBus) set_entry(e Entry) ! {
	b.usable('set_entry', false)!
	check_entry(e)!
	lock lin_inproc_reg {
		if b.is_closed() {
			return b.gone()
		}
		b.entries[e.id] = Entry{
			...e
			data: e.data.clone()
		}
	}
}

pub fn (mut b InprocBus) update(id u8, data []u8) ! {
	b.usable('update', false)!
	check_id(id)!
	lock lin_inproc_reg {
		if b.is_closed() {
			return b.gone()
		}
		e := b.entries[id] or { return error('lin: no publish entry for 0x${id:02X}') }
		if e.dir != .publish {
			return error('lin: no publish entry for 0x${id:02X}')
		}
		if data.len != e.len {
			return error('lin: 0x${id:02X} has length ${e.len}, not ${data.len}')
		}
		b.entries[id] = Entry{
			...e
			data: data.clone()
		}
	}
}

// Publisher is one handle's response to a header, as it goes on the wire.
struct Publisher {
	h     &InprocBus
	entry Entry
	bytes []u8
}

pub fn (mut b InprocBus) header(id u8) ! {
	b.usable('header', true)!
	check_id(id)!
	lock lin_inproc_reg {
		if b.is_closed() {
			return b.gone()
		}
		mut hub := lin_inproc_reg.hubs[b.name] or { return b.gone() }
		mut pubs := []Publisher{}
		for mut h in hub.handles {
			e := h.entries[id] or { continue }
			if e.dir != .publish || (id == slave_resp && !h.armed) {
				continue
			}
			if e.one_shot || id == slave_resp {
				h.entries.delete(id)
			}
			if id == slave_resp {
				h.armed = false
			}
			if e.inject == .silent {
				continue
			}
			pubs << Publisher{
				h:     h
				entry: e
				bytes: response_bytes(id, e)
			}
		}
		hub.resolve(b, id, pubs)
	}
}

// response_bytes is what an entry puts on the wire: its data and checksum, as its fault says.
fn response_bytes(id u8, e Entry) []u8 {
	mut cs := checksum(e.model, pid(id), e.data)
	if e.inject == .bad_checksum {
		cs ^= 0xFF
	}
	if e.inject == .short {
		return [e.data[0]]
	}
	mut out := e.data.clone()
	out << cs
	return out
}

// arbitrate is bitwise arbitration between publishers: bits go out LSB-first, byte by byte, the
// wire bit is the AND of the active publishers' bits (a dominant 0 wins), and a publisher that
// reads back a bit it did not send drops out at once (LIN 2.2A 2.3.1 permits aborting at the
// first mismatched bit). A publisher whose response ends stops sending without losing. Returns
// the wire bytes and which publishers lost; the wire is the longest surviving response.
fn arbitrate(pubs []Publisher) ([]u8, []bool) {
	mut lost := []bool{len: pubs.len}
	mut wire := []u8{}
	for i := 0; true; i++ {
		sending := []int{len: pubs.len, init: index}.filter(!lost[it] && i < pubs[it].bytes.len)
		if sending.len == 0 {
			break
		}
		mut w := u8(0)
		for bit in 0 .. 8 {
			mut level := u8(1)
			for k in sending {
				if !lost[k] {
					level &= (pubs[k].bytes[i] >> bit) & 1
				}
			}
			for k in sending {
				if !lost[k] && (pubs[k].bytes[i] >> bit) & 1 != level {
					lost[k] = true
				}
			}
			w |= level << bit
		}
		wire << w
	}
	return wire, lost
}

// resolve turns the publishers of one header into the frame every handle receives: none is no
// response; several arbitrate, and the wire carries the winner's response, read against the
// winner's entry, or by a handle with a subscribe entry for the id against its own. A loser's own copy carries `bit` and `collision`; nobody else can tell.
fn (mut hub LinHub) resolve(master &InprocBus, id u8, pubs []Publisher) {
	mut f := Frame{}
	wire, lost := arbitrate(pubs)
	if pubs.len == 0 {
		f = interpret(id, [], none)
		f.src = master.cfg.src
	} else {
		mut win := 0
		for k, p in pubs {
			if !lost[k] && p.bytes.len == wire.len {
				win = k
				break
			}
		}
		e := pubs[win].entry
		f = interpret(id, wire, Expect{ len: e.len, model: e.model })
		// The survivors' source when they share one; survivors of mixed sources are no one's.
		f.src = pubs[win].h.cfg.src
		for k, p in pubs {
			if !lost[k] && p.h.cfg.src != f.src {
				f.src = .remote
			}
		}
	}
	hub.last_id = id
	hub.state = if f.event == .sleep { State.sleep } else { State.active }
	if id == master_req {
		for mut h in hub.handles {
			h.armed = f.errs == Errs.zero() && f.event == .frame && h.cfg.nad != 0
				&& (f.data[0] == h.cfg.nad || f.data[0] == broadcast_nad)
		}
	}
	f.t_ns = hub.clock.now_ns()
	for mut h in hub.handles {
		mut c := Frame{
			...f
			header: h.id == master.id
		}
		for k, p in pubs {
			if p.h.id == h.id {
				c.ours = true
				if lost[k] {
					c.errs.set(.bit)
					c.errs.set(.collision)
					c.event = .frame
				}
			}
		}
		// A subscriber reads the wire by its own length and model.
		if e := h.entries[id] {
			if e.dir == .subscribe {
				c = reread(c, Expect{ len: e.len, model: e.model })
			}
		}
		h.push(c)
	}
}

fn (mut h InprocBus) push(f Frame) {
	// A copy of its own: a channel copies the struct, not the arrays behind data and raw.
	if h.queue.try_push(f.clone()) != .success {
		stdatomic.add_u64(&h.dropped, 1)
	}
}

// deliver puts an event this handle sent on the bus, to every handle.
fn (mut b InprocBus) deliver(f Frame, state State) ! {
	lock lin_inproc_reg {
		if b.is_closed() {
			return b.gone()
		}
		mut hub := lin_inproc_reg.hubs[b.name] or { return b.gone() }
		hub.state = state
		if f.event == .sleep {
			hub.last_id = master_req
			for mut h in hub.handles {
				h.armed = false
			}
		}
		g := Frame{
			...f
			src:  b.cfg.src
			t_ns: hub.clock.now_ns()
		}
		for mut h in hub.handles {
			h.push(Frame{
				...g
				ours:   h.id == b.id
				header: h.id == b.id && f.event == .sleep
			})
		}
	}
}

pub fn (mut b InprocBus) wakeup() ! {
	b.usable('wakeup', false)!
	b.deliver(Frame{ event: .wakeup }, .active)!
}

// sleep sends the go-to-sleep command: a MasterReq of 0x00 and seven 0xFF, classic checksum.
pub fn (mut b InprocBus) sleep() ! {
	b.usable('sleep', true)!
	data := sleep_data()
	mut raw := data.clone()
	raw << checksum(.classic, pid(master_req), data)
	b.deliver(interpret(master_req, raw, Expect{ len: 8, model: .classic }), .sleep)!
}

// recv: a closed handle is gone, whatever is still queued on it.
pub fn (mut b InprocBus) recv(timeout_ms int) !Frame {
	if b.is_closed() {
		return b.gone()
	}
	f := b.pop(timeout_ms)!
	if b.is_closed() {
		return b.gone()
	}
	return f
}

fn (mut b InprocBus) pop(timeout_ms int) !Frame {
	if timeout_ms == 0 {
		mut f := Frame{}
		return match b.queue.try_pop(mut f) {
			.success { f }
			.closed { b.gone() }
			.not_ready { Timeout{} }
		}
	}
	if timeout_ms < 0 {
		f := <-b.queue or { return b.gone() }
		return f
	}
	// The select is an expression: its false is the closed channel.
	mut got := false
	mut frame := Frame{}
	chan_open := select {
		f := <-b.queue {
			got = true
			frame = f
		}
		(i64(timeout_ms) * time.millisecond) {
		}
	}
	if got {
		return frame
	}
	if !chan_open {
		return b.gone()
	}
	return Timeout{}
}

pub fn (mut b InprocBus) status() Status {
	rlock lin_inproc_reg {
		if hub := lin_inproc_reg.hubs[b.name] {
			return Status{
				state:   hub.state
				last_id: hub.last_id
			}
		}
	}
	return Status{}
}

// diagnostics: frames this handle's queue had no room for.
pub fn (mut b InprocBus) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{
		dropped: stdatomic.load_u64(&b.dropped)
	}
}

// close detaches the handle, drops its entries and frees the master slot; the last handle to
// leave ends the bus.
pub fn (mut b InprocBus) close() {
	lock lin_inproc_reg {
		if stdatomic.load_u64(&b.closed) != 0 {
			return
		}
		stdatomic.store_u64(&b.closed, 1)
		b.entries.clear()
		if mut hub := lin_inproc_reg.hubs[b.name] {
			hub.handles = hub.handles.filter(it.id != b.id)
			if hub.master == b.id {
				hub.master = 0
			}
			if hub.handles.len == 0 {
				lin_inproc_reg.hubs.delete(b.name)
			}
		}
	}
	b.queue.close()
}
