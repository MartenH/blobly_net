// Listener is the reading of one handle's frames for a script: the transport protocol rejoined
// (Reassembler) and the address directory (Directory), fed with every frame the handle reads, so a
// frame is still consumed once by whoever reads it and the script's own sends are never in it.
// Completed messages and faults wait in bounded queues until the script takes them. Like the rest
// of this module it sends nothing: no CTS, no acknowledgement, no address claim.
module j1939

import blobly.transport

// listener_queue is how many completed messages, and how many faults, a listener keeps untaken;
// past it the oldest is dropped and counted (`dropped`).
pub const listener_queue = 1024

pub struct Listener {
pub mut:
	tp  Reassembler
	dir Directory
mut:
	done   Queue[Assembled]
	faults Queue[Fault]
pub mut:
	// messages and faults dropped untaken because the queue was full
	dropped int
}

// Queue is a bounded first-in first-out queue, taken from a head index and compacted once half of
// it is taken, so each take is O(1) amortised.
struct Queue[T] {
mut:
	items []T
	head  int
}

fn (q Queue[T]) len() int {
	return q.items.len - q.head
}

// push appends `x`, dropping the oldest when the queue holds listener_queue; true when it dropped.
fn (mut q Queue[T]) push(x T) bool {
	dropped := q.len() >= listener_queue
	if dropped {
		q.head++
	}
	q.items << x
	q.compact()
	return dropped
}

fn (q Queue[T]) peek() ?T {
	if q.len() == 0 {
		return none
	}
	return q.items[q.head]
}

fn (mut q Queue[T]) take() ?T {
	if q.len() == 0 {
		return none
	}
	x := q.items[q.head]
	q.head++
	q.compact()
	return x
}

fn (mut q Queue[T]) compact() {
	if q.head > 0 && q.head * 2 >= q.items.len {
		q.items = q.items[q.head..].clone()
		q.head = 0
	}
}

// feed observes one frame the handle read at `t_ms` (host monotonic milliseconds): an Address
// Claimed frame moves the directory, and every frame reaches the reassembler, which also expires
// the stalled sessions (a standard frame says time passed as well).
pub fn (mut l Listener) feed(f transport.CanFrame, t_ms f64) {
	if !f.extended || f.rtr {
		l.idle(t_ms)
		return
	}
	id := decompose(f.id)
	if claim_frame(f, id) {
		l.dir.observe(id.sa, f.data, t_ms) or {}
	}
	ev := l.tp.feed(f, t_ms)
	for a in ev.done {
		if l.done.push(a) {
			l.dropped++
		}
	}
	for fl in ev.faults {
		l.push_fault(fl)
	}
}

// idle expires the sessions stalled at `t_ms`, for a reader that found nothing queued: a sender
// that stopped mid-transfer is said even when no further frame comes.
pub fn (mut l Listener) idle(t_ms f64) {
	if l.tp.open() == 0 {
		return
	}
	for fl in l.tp.expire(t_ms) {
		l.push_fault(fl)
	}
}

fn (mut l Listener) push_fault(f Fault) {
	if l.faults.push(f) {
		l.dropped++
	}
}

// peek_message is the oldest completed message, left queued.
pub fn (l Listener) peek_message() ?Assembled {
	return l.done.peek()
}

// next_message takes the oldest completed message.
pub fn (mut l Listener) next_message() ?Assembled {
	return l.done.take()
}

// queued is how many completed messages wait to be taken.
pub fn (l Listener) queued() int {
	return l.done.len()
}

// next_fault takes the oldest fault.
pub fn (mut l Listener) next_fault() ?Fault {
	return l.faults.take()
}

// on_wire is whether row `i` of a run reads as J1939: a row on its wire (`keys`, each row's
// destination key) says so (`says`: its `j1939:` tick, or a database declaring J1939) — the GUI's
// per-wire gate, since aliasing rows carry one wire's frames.
pub fn on_wire(keys []string, says []bool, i int) bool {
	for k, key in keys {
		if key == keys[i] && says[k] {
			return true
		}
	}
	return false
}
