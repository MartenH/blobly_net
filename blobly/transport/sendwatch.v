module transport

import sync
import sync.stdatomic

// SendWatch is told of every frame this process puts on one wire, from SilentBus.send — the one
// door every bus `open` hands out sends through: `before` as the frame goes to the driver,
// answering a token, then `after` with that token and what the driver did with it. Told before,
// so a reader of the wire cannot see the frame come back ahead of the note (a recorder:
// blobly/replay). Both are called on the sending thread; a watch must not send.
pub struct SendWatch {
pub:
	before fn (f CanFrame) u64 @[required]
	after  fn (token u64, out Sent) @[required]
}

// Sent is what became of a watched send.
pub enum Sent {
	taken   // the driver took it
	refused // refused before anything was written (NotWritten)
	unknown // the write failed, and may still have put the frame on the wire
}

struct Watched {
	wire string
	w    SendWatch
}

struct SendWatches {
mut:
	mu   sync.Mutex
	n    i64 // how many are registered: a send with none asks nothing more
	next int
	by   map[int]Watched
}

__global send_watches = &SendWatches{}

// watch_sends registers `w` on the wire `iface` reaches (wire_key) and answers its id.
pub fn watch_sends(iface string, w SendWatch) int {
	mut s := send_watches
	s.mu.lock()
	id := s.next
	s.next++
	s.by[id] = Watched{
		wire: wire_key(iface)
		w:    w
	}
	stdatomic.store_i64(&s.n, i64(s.by.len))
	s.mu.unlock()
	return id
}

// unwatch_sends removes watch `id`; a send already past `before` still gets its `after`.
pub fn unwatch_sends(id int) {
	mut s := send_watches
	s.mu.lock()
	s.by.delete(id)
	stdatomic.store_i64(&s.n, i64(s.by.len))
	s.mu.unlock()
}

// sends_watched is whether any watch is registered: a send asks nothing more when none is.
fn sends_watched() bool {
	return stdatomic.load_i64(&send_watches.n) != 0
}

// watch_before tells the watches on `iface`'s wire that `f` goes to the driver now, and answers
// them with their tokens, for watch_after.
fn watch_before(iface string, f CanFrame) ([]SendWatch, []u64) {
	wire := wire_key(iface)
	mut s := send_watches
	s.mu.lock()
	mut ws := []SendWatch{}
	for _, w in s.by {
		if w.wire == wire {
			ws << w.w
		}
	}
	s.mu.unlock()
	mut toks := []u64{cap: ws.len}
	for w in ws {
		toks << w.before(f)
	}
	return ws, toks
}

// watch_after tells the watches watch_before told what became of the frame.
fn watch_after(ws []SendWatch, toks []u64, out Sent) {
	for i, w in ws {
		w.after(toks[i], out)
	}
}
