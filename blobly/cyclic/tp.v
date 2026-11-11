// tp.v — a long J1939 message an entry sends on a wire's loop (wire.v) without holding the loop:
// a BAM's frames each sent when its pacer says (j1939.Pacer), an RTS/CTS connection stepped each
// pass (j1939.Originator) on the answers a handle of its own reads, so every other entry on the
// wire keeps its grid while the transfer runs. One transfer at a time per entry.
module cyclic

import math
import time
import blobly.j1939
import blobly.transport

// conn_poll_ms is how often a connection in progress looks for its peer's answers.
const conn_poll_ms = u64(2)

// lane_retry_ms is how often a connection waiting for its lane (another sender in this process
// has a connection between the same two addresses) asks again.
const lane_retry_ms = u64(5)

// conn_reads is the most answers a connection reads in one pass.
const conn_reads = 64

// Step is where a send stands: `going` while its transfer runs, else ended — sent whole when
// `why` is '', else why not.
pub struct Step {
pub:
	going bool
	why   string
}

// Tp is one entry's message send on a wire's loop: begin starts it, pump drives a transfer it
// began, quit ends one at a stop.
pub struct Tp {
mut:
	pacer   j1939.Pacer
	bam     bool // a BAM is in progress
	count   int  // its frames
	sent    int  // of them, the ones the bus took
	conn    j1939.Originator
	in_conn bool // a connection is in progress
	opened  bool // its RTS went out: its lane is held and its reader open
	rd      ?transport.Bus
	own_rd  bool // rd was opened for it (else it is the wire's handle)
	look_at u64  // when a connection looks for its lane or its answers next (ms, monotonic)
	took    bool // a frame of the send went out
}

// busy is whether a transfer is in progress.
pub fn (t &Tp) busy() bool {
	return t.bam || t.in_conn
}

// took_frame is whether a frame of the send last begun went out.
pub fn (t &Tp) took_frame() bool {
	return t.took
}

// begin sends message frame `f` (`declared` whether its database declares it J1939) on `bus` as
// j1939.plan_message says: the one frame now, else the first step of its BAM or its connection,
// which pump drives from then.
pub fn (mut t Tp) begin(mut bus transport.Bus, f transport.CanFrame, declared bool, now u64) Step {
	t.took = false
	p := j1939.plan_message(bus, f, declared) or { return Step{
		why: err.msg()
	} }
	if p.connection {
		t.conn = j1939.connection_for(f, transport.wire_of(bus), 0) or {
			return Step{
				why: err.msg()
			}
		}
		t.in_conn = true
		t.opened = false
		return t.pump(mut bus, now)
	}
	if p.frames.len == 1 {
		bus.send(p.frames[0]) or { return Step{
			why: err.msg()
		} }
		t.took = true
		return Step{}
	}
	t.pacer.add(transport.wire_of(bus), p.frames, 0)
	t.bam = true
	t.count = p.frames.len
	t.sent = 0
	return t.pump(mut bus, now)
}

// due is when pump has something to do (ms on the monotonic clock), while busy.
pub fn (t &Tp) due(now u64) u64 {
	if t.bam {
		next := t.pacer.next_ms(f64(now)) or { return now }
		return if next <= f64(now) { now } else { u64(math.ceil(next)) }
	}
	return t.look_at
}

// pump drives the transfer in progress at `now` (ms on the monotonic clock): a BAM's frame when
// due, a connection's start once its lane is free, its answers read and what they clear sent.
pub fn (mut t Tp) pump(mut bus transport.Bus, now u64) Step {
	if t.bam {
		return t.pump_bam(mut bus, now)
	}
	if t.in_conn {
		st := t.pump_conn(mut bus)
		t.look_at = now + if t.opened { conn_poll_ms } else { lane_retry_ms }
		return st
	}
	return Step{}
}

fn (mut t Tp) pump_bam(mut bus transport.Bus, now u64) Step {
	for d in t.pacer.take(f64(now)) {
		bus.send(d.frame) or {
			t.pacer.settle(d, false, mono_ms())
			t.bam = false
			return Step{
				why: 'transport frame ${t.sent + 1} of ${t.count}: ${err.msg()}'
			}
		}
		t.sent++
		t.took = true
		if t.pacer.settle(d, true, mono_ms()) {
			t.bam = false
			return Step{}
		}
	}
	if t.pacer.pending() == 0 {
		t.bam = false
		return Step{
			why: 'transport frame ${t.sent + 1} of ${t.count}: the source address was lost after a stall'
		}
	}
	return Step{
		going: true
	}
}

fn (mut t Tp) pump_conn(mut bus transport.Bus) Step {
	if !t.opened {
		if !t.conn.take_lane(time.sys_mono_now()) {
			return Step{
				going: true
			}
		}
		// opened once the lane is ours, so no answer to the connection that held it is read as one
		wire := transport.wire_of(bus)
		mut rd := bus // copy: an interface value, the same bus
		if wire != '' {
			rd = transport.open(wire) or {
				t.conn.free_lane(time.sys_mono_now())
				t.in_conn = false
				return Step{
					why: 'cannot open ${wire} for its answers: ${err.msg()}'
				}
			}
		}
		// subscribed before the RTS goes out, so its answer cannot pass the reader by
		rd.recv(0) or {}
		t.rd = rd
		t.own_rd = wire != ''
		t.opened = true
		out := t.conn.start(mono_ms())
		return t.conn_out(mut bus, out)
	}
	if !t.conn.take_lane(time.sys_mono_now()) {
		return t.conn_lost()
	}
	out := t.conn.poll(mono_ms())
	if out.end != .open {
		return t.conn_out(mut bus, out)
	}
	mut rd := t.rd or { return t.conn_end('no reader for its answers') }
	for _ in 0 .. conn_reads {
		fr := rd.recv(0) or {
			if err.msg() == 'timeout' || transport.look_was_spent(err) {
				break
			}
			for a in t.conn.stop().frames {
				bus.send(a) or {}
			}
			return t.conn_end(err.msg())
		}
		st := t.conn_out(mut bus, t.conn.feed(fr, mono_ms()))
		if !st.going {
			return st
		}
	}
	return Step{
		going: true
	}
}

// conn_out sends what a connection step produced, in order, and says where it stands.
fn (mut t Tp) conn_out(mut bus transport.Bus, out j1939.ConnOut) Step {
	for x in out.frames {
		if out.end == .open && j1939.pgn(x.id) == j1939.pgn_tp_dt
			&& !t.conn.take_lane(time.sys_mono_now()) {
			return t.conn_lost()
		}
		bus.send(x) or {
			if t.conn.open() {
				for a in t.conn.stop().frames {
					bus.send(a) or {}
				}
			}
			return t.conn_end(err.msg())
		}
		t.took = true
	}
	if out.frames.len > 0 {
		t.conn.wrote(mono_ms())
	}
	return match out.end {
		.open { Step{
				going: true
			} }
		.done { t.conn_end('') }
		else { t.conn_end(out.detail) }
	}
}

// conn_lost ends a connection whose lane another sender took: nothing more is sent, its abort
// included, since that sender's connection runs between the same two addresses.
fn (mut t Tp) conn_lost() Step {
	return t.conn_end('another sender in this process took its lane; nothing more sent')
}

// conn_end lets the connection's lane and reader go; `why` '' it completed.
fn (mut t Tp) conn_end(why string) Step {
	if t.opened {
		t.conn.free_lane(time.sys_mono_now())
	}
	if t.own_rd {
		if mut rd := t.rd {
			rd.close()
		}
	}
	t.rd = none
	t.own_rd = false
	t.opened = false
	t.in_conn = false
	return Step{
		why: why
	}
}

// quit ends the transfer in progress, for a stop: a BAM's lane let go with the rest unsent, a
// connection aborted on `bus` (reason 250).
pub fn (mut t Tp) quit(mut bus transport.Bus) {
	if t.bam {
		t.pacer.abandon(0)
		t.bam = false
	}
	if t.in_conn {
		if t.opened {
			for a in t.conn.stop().frames {
				bus.send(a) or {}
			}
		}
		t.conn_end('')
	}
}

// mono_ms is the monotonic clock in ms, the clock a wire's loop runs on.
fn mono_ms() f64 {
	return f64(time.sys_mono_now()) / 1_000_000.0
}
