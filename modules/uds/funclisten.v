module uds

import isotp
import sync
import transport

// funclisten.v — the functional listener: ONE raw subscription per wire, shared by every served
// node that answers a functional id on it. Each node used to open its own, so every frame on a
// busy wire was queued and inspected once more per node, and a node blocked in a long send let
// its own queue overflow and lose the broadcast it existed for. Whichever node polls drains the
// wire for all of them, and a node that is busy loses at most its own bounded backlog.

// func_queue_cap bounds what one node may have waiting: a request older than that is past any
// tester's reply window.
const func_queue_cap = 32

struct FuncWire {
	key string
mut:
	mu   &sync.Mutex = sync.new_mutex()
	bus  transport.Bus
	subs []&FuncSub
}

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

struct FuncRegistry {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	wires map[string]&FuncWire
}

__global func_registry = &FuncRegistry{}

// functional_join puts a node answering `fid` on `iface`'s functional listener, opening the wire
// with `open` if no node has yet. The open runs outside the registry lock, so a slow device
// stalls only its own wire's joiners; a join that loses the race closes its bus and shares.
pub fn functional_join(iface string, fid u32, fext bool, open fn () !transport.Bus) !&FuncSub {
	key := transport.destination_key(iface)
	mut sub := &FuncSub{
		fid:  fid
		fext: fext
	}
	mut r := func_registry
	r.mu.lock()
	if mut w := r.wires[key] {
		w.mu.lock()
		sub.wire = w
		w.subs << sub
		w.mu.unlock()
		r.mu.unlock()
		return sub
	}
	r.mu.unlock()
	mut bus := open()!
	r.mu.lock()
	if mut w := r.wires[key] {
		w.mu.lock()
		sub.wire = w
		w.subs << sub
		w.mu.unlock()
		r.mu.unlock()
		bus.close()
		return sub
	}
	mut w := &FuncWire{
		key:  key
		bus:  bus
		subs: [sub]
	}
	sub.wire = w
	r.wires[key] = w
	r.mu.unlock()
	return sub
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
fn (mut w FuncWire) pump() {
	for {
		f := w.bus.recv(0) or { break }
		if f.rtr {
			continue
		}
		mut req := []u8{}
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
			s.q << req.clone()
		}
	}
}

// leave takes the node off its wire; the last one out closes the bus. Returns what is worth
// reporting: this node's dropped backlog, plus the wire's own diagnostics when this closed it.
// Idempotent.
pub fn (mut s FuncSub) leave() transport.BusDiagnostics {
	if s.left {
		return transport.BusDiagnostics{}
	}
	s.left = true
	mut r := func_registry
	mut w := s.wire
	r.mu.lock()
	w.mu.lock()
	w.subs = w.subs.filter(voidptr(it) != voidptr(&s))
	last := w.subs.len == 0
	if last {
		r.wires.delete(w.key)
	}
	mut d := transport.BusDiagnostics{
		dropped: s.dropped
	}
	w.mu.unlock()
	r.mu.unlock()
	if last {
		wd := w.bus.diagnostics()
		d.dropped += wd.dropped
		d.bus_errors = wd.bus_errors
		d.decode_errors = wd.decode_errors
		w.bus.close()
	}
	return d
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
