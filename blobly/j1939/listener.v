// Listener is the reading of one handle's frames for a script: the transport protocol rejoined
// (Reassembler) and the address directory (Directory), fed with every frame the handle reads, so a
// frame is still consumed once by whoever reads it and the script's own sends are never in it.
// Completed messages and faults wait in bounded queues until the script takes them. It sends nothing
// of its own accord — no address claim — but where `answer` names an address the handle holds, an
// RTS aimed at it is answered (Responder): the frames to send wait in `take_outgoing` for the
// reader, which sends them on the handle.
module j1939

import blobly.transport

// listener_queue is how many completed messages, and how many faults, a listener keeps untaken;
// past it the oldest is dropped and counted (`dropped`).
pub const listener_queue = 1024

pub struct Listener {
pub mut:
	tp  Reassembler
	dir Directory
	// the RTS/CTS connections answered for the address set by `answer`
	answers Responder
mut:
	done     Queue[Assembled]
	faults   Queue[Fault]
	outgoing []transport.CanFrame
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
	l.outgoing << l.answers.poll(t_ms)
	l.outgoing << l.answers.feed(f, t_ms)
	ev := l.tp.feed(f, t_ms)
	for a in ev.done {
		if l.done.push(a) {
			l.dropped++
		}
	}
	for fl in ev.faults {
		l.push_fault(fl)
	}
	l.outgoing << l.answers.abort_unheld(l.tp)
}

// idle expires the sessions stalled at `t_ms`, for a reader that found nothing queued: a sender
// that stopped mid-transfer is said even when no further frame comes.
pub fn (mut l Listener) idle(t_ms f64) {
	l.outgoing << l.answers.poll(t_ms)
	if l.tp.open() > 0 {
		for fl in l.tp.expire(t_ms) {
			l.push_fault(fl)
		}
	}
	l.outgoing << l.answers.abort_unheld(l.tp)
}

// answer makes the listener answer RTS/CTS connections aimed at `address` (0..0xFD), as the node
// holding it: none (-1) answers nothing. A connection being answered for another address ends
// unanswered; the same address again changes nothing.
pub fn (mut l Listener) answer(address int) ! {
	if address < -1 || address > 0xFD {
		return error('an address a node holds is 0x00..0xFD, not ${address}')
	}
	if address == l.answering() {
		return
	}
	l.answers = Responder{
		addresses: if address < 0 { []u8{} } else { [u8(address)] }
	}
}

// answering is the address the listener answers for, -1 none.
pub fn (l Listener) answering() int {
	return if l.answers.addresses.len > 0 { int(l.answers.addresses[0]) } else { -1 }
}

// take_outgoing is what the listener has to send since it was last asked: the answers to the
// connections aimed at its address, for the reader to send on its handle in order.
pub fn (mut l Listener) take_outgoing() []transport.CanFrame {
	out := l.outgoing
	l.outgoing = []
	return out
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
