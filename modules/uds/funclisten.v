module uds

import isotp
import sync
import time
import transport

// funclisten.v — the functional listener: ONE raw subscription per wire, shared by every served
// node that answers a functional id on it. Each node used to open its own, so every frame on a
// busy wire was queued and inspected once more per node, and a node blocked in a long send let
// its own queue overflow and lose the broadcast it existed for. Whichever node polls drains the
// wire for all of them, and a node that is busy loses at most its own bounded backlog.

// func_queue_cap bounds what one node may have waiting: a request older than that is past any
// tester's reply window.
const func_queue_cap = 32

// FuncWire is one wire's listener. Its first joiner holds `mu` through the open, so every other
// joiner waits on that one attempt and shares its outcome. Lock order: `mu`, then the registry's.
struct FuncWire {
	key string
mut:
	mu       &sync.Mutex = sync.new_mutex()
	bus      transport.Bus
	open     fn () !transport.Bus = unsafe { nil }
	subs     []&FuncSub
	failed   string // why the FIRST open failed; the wire is out of the registry then
	closed   bool   // its last node left; a joiner that was waiting starts over
	broken   bool   // a receive failed: the bus is closed and reopened in place, for every node
	retry_at i64    // when a broken wire may next try to reopen (time.ticks)
	prior    transport.BusDiagnostics // what the bus generations closed on a failure counted
}

// func_reopen_ms paces a broken wire's reopen attempts, which run on a node's poll.
const func_reopen_ms = 500

// FuncSub is one node's place on a wire's functional listener: the requests addressed to its
// functional id, as decoded Single Frame payloads.
@[heap]
pub struct FuncSub {
pub:
	fid  u32
	fext bool
mut:
	wire    &FuncWire = unsafe { nil }
	q       [][]u8
	dropped u64
	left    bool
}

// FuncLeave is what a node's leaving has worth reporting: its own queue's losses, and the wire's
// diagnostics when it was the last one out and closed the bus.
pub struct FuncLeave {
pub:
	fid           u32
	queue_dropped u64
	wire          ?transport.BusDiagnostics
}

struct FuncRegistry {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	wires map[string]&FuncWire
}

__global func_registry = &FuncRegistry{}

// functional_join puts a node answering `fid` on `iface`'s functional listener, opening the wire
// with `open` if no node has yet. The open runs outside the registry lock, so a slow device
// stalls only its own wire's joiners, and once per wire: a joiner arriving meanwhile waits for
// that attempt and shares its outcome, a failure included.
pub fn functional_join(iface string, fid u32, fext bool, open fn () !transport.Bus) !&FuncSub {
	key := transport.destination_key(iface)
	mut sub := &FuncSub{
		fid:  fid
		fext: fext
	}
	mut r := func_registry
	for {
		r.mu.lock()
		mut w := r.wires[key] or { break }
		r.mu.unlock()
		w.mu.lock() // waits out an open in progress
		if w.closed {
			w.mu.unlock()
			continue
		}
		if w.failed != '' {
			why := w.failed
			w.mu.unlock()
			return error(why)
		}
		w.pump() // what arrived before this node joined is not addressed to it
		sub.wire = w
		w.subs << sub
		w.mu.unlock()
		return sub
	}
	// still holding r.mu: nobody has this wire
	mut w := &FuncWire{
		key: key
	}
	w.mu.lock()
	r.wires[key] = w
	r.mu.unlock()
	defer {
		w.mu.unlock()
	}
	w.bus = open() or {
		w.failed = err.msg()
		w.retire()
		return err
	}
	w.open = open
	sub.wire = w
	w.subs << sub
	return sub
}

// retire takes the wire out of the registry, if it is still the one registered under its key.
fn (w &FuncWire) retire() {
	mut r := func_registry
	r.mu.lock()
	if cur := r.wires[w.key] {
		if voidptr(cur) == voidptr(w) {
			r.wires.delete(w.key)
		}
	}
	r.mu.unlock()
}

// take returns the oldest functional request waiting for this node, after draining what the
// wire has delivered into every node's queue.
pub fn (mut s FuncSub) take() ?[]u8 {
	if s.left {
		return none
	}
	mut w := s.wire
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	w.pump()
	if s.q.len == 0 {
		return none
	}
	req := s.q[0]
	s.q.delete(0)
	return req
}

// pump hands every queued frame to the nodes whose functional id it carries. Held under w.mu.
// A receive that fails for any reason but silence closes the bus and marks the wire broken; the
// wire stays registered with every node on it and is reopened IN PLACE, so no node is stranded
// on a dead bus and a later joiner does not open a second listener beside it.
fn (mut w FuncWire) pump() {
	if w.broken {
		now := time.ticks()
		if now < w.retry_at {
			return
		}
		w.bus = w.open() or {
			w.retry_at = now + func_reopen_ms
			return
		}
		w.broken = false
	}
	for {
		f := w.bus.recv(0) or {
			if !is_silence(err.msg()) {
				w.prior = w.prior.plus(w.bus.diagnostics())
				w.bus.close()
				w.broken = true
				w.retry_at = time.ticks()
			}
			break
		}
		if f.rtr {
			continue
		}
		mut req := []u8{}
		mut given := false
		for mut s in w.subs {
			if s.fid != f.id || s.fext != f.extended {
				continue
			}
			if req.len == 0 {
				req = isotp.single_frame(f.data) or { break } // functional: one Single Frame
			}
			if s.q.len >= func_queue_cap {
				s.q.delete(0)
				s.dropped++
			}
			s.q << if given { req.clone() } else { req }
			given = true
		}
	}
}

// leave takes the node off its wire; the last one out closes the bus. Idempotent.
pub fn (mut s FuncSub) leave() FuncLeave {
	if s.left {
		return FuncLeave{
			fid: s.fid
		}
	}
	s.left = true
	mut w := s.wire
	w.mu.lock()
	w.subs = w.subs.filter(voidptr(it) != voidptr(&s))
	last := w.subs.len == 0
	if last {
		w.closed = true
		w.retire()
	}
	w.mu.unlock()
	if !last {
		return FuncLeave{
			fid:           s.fid
			queue_dropped: s.dropped
		}
	}
	mut d := w.prior
	if !w.broken {
		d = d.plus(w.bus.diagnostics())
		w.bus.close()
	}
	return FuncLeave{
		fid:           s.fid
		queue_dropped: s.dropped
		wire:          d
	}
}

// functional_wires is how many wires have a functional listener open.
fn functional_wires() int {
	mut r := func_registry
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	return r.wires.len
}
