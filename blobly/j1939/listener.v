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
	done   []Assembled
	faults []Fault
pub mut:
	// messages and faults dropped untaken because the queue was full
	dropped int
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
		l.push_done(a)
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

fn (mut l Listener) push_done(a Assembled) {
	if l.done.len >= listener_queue {
		l.done.delete(0)
		l.dropped++
	}
	l.done << a
}

fn (mut l Listener) push_fault(f Fault) {
	if l.faults.len >= listener_queue {
		l.faults.delete(0)
		l.dropped++
	}
	l.faults << f
}

// next_message takes the oldest completed message.
pub fn (mut l Listener) next_message() ?Assembled {
	if l.done.len == 0 {
		return none
	}
	a := l.done[0]
	l.done.delete(0)
	return a
}

// peek_message is the oldest completed message, left queued.
pub fn (l Listener) peek_message() ?Assembled {
	if l.done.len == 0 {
		return none
	}
	return l.done[0]
}

// next_fault takes the oldest fault.
pub fn (mut l Listener) next_fault() ?Fault {
	if l.faults.len == 0 {
		return none
	}
	f := l.faults[0]
	l.faults.delete(0)
	return f
}

// queued is how many completed messages wait to be taken.
pub fn (l Listener) queued() int {
	return l.done.len
}
