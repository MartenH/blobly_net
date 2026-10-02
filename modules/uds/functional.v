module uds

import isotp
import time
import transport

// functional.v — one request to many servers (ISO 14229-2 functional addressing, ISO 15765-2 on
// CAN): the request goes out ONCE, as a Single Frame on the functional id (a functional request
// cannot be segmented: the peers could not each answer a Flow Control), and every server that
// answers does so on its own PHYSICAL response id — a multi-frame answer included, whose Flow
// Control the tester sends on that server's physical REQUEST id. So each target is a physical
// Client, whose channel reassembles its answer and sends that Flow Control, and a raw tap on the
// bus says which target has begun to answer, so its channel is read with a real deadline and the
// others' frames wait queued in theirs. (A software ISO-TP read gives the whole PDU one deadline,
// so polling every target with a zero timeout would abort a multi-frame answer mid-transfer.)
// One answer is reassembled at a time: a second target's First Frame gets its Flow Control once
// the first transfer ends — milliseconds for an ordinary answer, well inside the peer's N_Bs.

// FunctionalTarget is one server a functional request may reach: its physical client and the id
// (and width) its answers arrive on.
pub struct FunctionalTarget {
pub mut:
	client &Client
	rsp_id u32
	ext    bool
}

pub enum FunctionalOutcome {
	positive
	negative
	silent // nothing within the window: normal for a functional request (ISO 14229-1 suppresses
	// NRC 0x11/0x12/0x31/0x7E/0x7F to one), and what a suppressed positive response looks like
	pending // said responsePending and then nothing within its P2*
	failed  // a malformed answer, or the channel failed while reading one
}

pub struct FunctionalReply {
pub:
	outcome FunctionalOutcome
	resp    []u8 // the positive answer, or the negative one (7F <sid> <nrc>)
	nrc     u8
	pended  bool   // said responsePending (0x78) on the way
	err     string // why, for .failed
}

// max_functional_payload: what a classic Single Frame carries.
pub const max_functional_payload = 7

// functional sends `req` once on `fch` (an ISO-TP channel whose tx id is the functional id) and
// collects each target's answer, returned in the order of `targets`. `tap` is a raw subscription
// to the same bus, opened by the caller BEFORE this call so nothing sent after the request is
// missed. `window_ms` bounds the first answer from every target; a target that says 0x78 is waited
// for its own P2* after it (+ margin), never past its client's pending_budget_ms.
pub fn functional(mut fch isotp.Channel, mut tap transport.Bus, targets []FunctionalTarget, req []u8, window_ms int) ![]FunctionalReply {
	if req.len == 0 {
		return error('empty UDS request')
	}
	if req.len > max_functional_payload {
		return error('UDS: a functional request is one Single Frame (${max_functional_payload} bytes), not ${req.len}')
	}
	for i, t in targets {
		for j in 0 .. i {
			if targets[j].rsp_id == t.rsp_id && targets[j].ext == t.ext {
				return error('UDS: two functional targets answer on 0x${t.rsp_id:X}')
			}
		}
	}
	// what is already queued is no answer to this request: the same drain a physical exchange runs.
	// The tap FIRST: a frame arriving between the two drains then still has its trigger, and a
	// trigger whose PDU the channel drain took finds the channel empty — read as silence below.
	for {
		tap.recv(0) or { break }
	}
	for t in targets {
		mut c := t.client
		c.drain_queued(req[0])!
	}
	fch.send(req)!
	sw := time.new_stopwatch()
	mut deadline := []i64{len: targets.len, init: i64(window_ms)}
	mut pended := []bool{len: targets.len}
	mut done := []FunctionalReply{len: targets.len}
	mut finished := []bool{len: targets.len}
	for {
		now := sw.elapsed().milliseconds()
		mut until := i64(-1)
		for i, fin in finished {
			if fin {
				continue
			}
			if now >= deadline[i] {
				// its window is over: what it says after is not counted, whoever else is waited for
				done[i] = FunctionalReply{
					outcome: if pended[i] { .pending } else { .silent }
					pended:  pended[i]
				}
				finished[i] = true
			} else if deadline[i] > until {
				until = deadline[i]
			}
		}
		if until < 0 {
			break
		}
		f := tap.recv(int(until - now)) or {
			if is_silence(err.msg()) {
				continue
			}
			return error('UDS: the functional listener failed: ${err.msg()}')
		}
		// the START of an answer: a Single Frame (0x0_) or a First Frame (0x1_); consecutive
		// frames belong to a reassembly a channel is already running
		if f.data.len == 0 || f.data[0] >> 4 > 1 {
			continue
		}
		i := target_of(targets, f) or { continue }
		if finished[i] {
			continue
		}
		mut c := targets[i].client
		// an answer that has begun is given the time a physical read would have to finish, not what
		// is left of the window: a First Frame near its end would otherwise abort mid-transfer
		left := deadline[i] - sw.elapsed().milliseconds()
		read_ms := if left > c.timeout_ms { left } else { i64(c.timeout_ms) }
		resp := c.ch.recv(int(read_ms)) or {
			if is_silence(err.msg()) {
				continue // its PDU was taken by the pre-send drain: nothing of this request's yet
			}
			done[i] = FunctionalReply{
				outcome: .failed
				pended:  pended[i]
				err:     err.msg()
			}
			finished[i] = true
			continue
		}
		verdict, reply := heard(mut c, req, resp, pended[i])
		match verdict {
			.settled {
				done[i] = reply
				finished[i] = true
			}
			.pending {
				pended[i] = true
				deadline[i] = c.pending_deadline(sw.elapsed().milliseconds())
			}
			.stale {}
		}
	}
	mut out := []FunctionalReply{cap: targets.len}
	for i, d in done {
		out << if finished[i] {
			d
		} else {
			FunctionalReply{
				outcome: if pended[i] { .pending } else { .silent }
				pended:  pended[i]
			}
		}
	}
	return out
}

fn target_of(targets []FunctionalTarget, f transport.CanFrame) ?int {
	for i, t in targets {
		if t.rsp_id == f.id && t.ext == f.extended {
			return i
		}
	}
	return none
}

enum Heard {
	settled // the target's reply is final
	pending // responsePending: wait for its P2*
	stale   // an answer to another request: keep waiting
}

// heard is what one answer `resp` to the functional `req` means for its target — the rule both
// forms (CAN and addressed) share, so they cannot classify one answer two ways.
fn heard(mut c Client, req []u8, resp []u8, pended bool) (Heard, FunctionalReply) {
	match answer_to(req, resp) {
		.positive {
			if req[0] == sid_diagnostic_session_control {
				c.adopt(resp)
			}
			return Heard.settled, FunctionalReply{
				outcome: .positive
				resp:    resp
				pended:  pended
			}
		}
		.negative {
			return Heard.settled, FunctionalReply{
				outcome: .negative
				resp:    resp
				nrc:     resp[2]
				pended:  pended
			}
		}
		.pending {
			return Heard.pending, FunctionalReply{}
		}
		.malformed {
			return Heard.settled, FunctionalReply{
				outcome: .failed
				resp:    resp
				pended:  pended
				err:     'malformed UDS response to 0x${req[0]:02X}: ${resp.hex()}'
			}
		}
		.stale {
			return Heard.stale, FunctionalReply{}
		}
	}
}

// pending_deadline is when a target that said responsePending at `at` (ms into the request) has
// to have answered: its P2* plus margin, never past its pending_budget_ms.
fn (c &Client) pending_deadline(at i64) i64 {
	wait := i64(c.p2_star_ms) + c.margin_ms
	return if at + wait < c.pending_budget_ms { at + wait } else { i64(c.pending_budget_ms) }
}

// AddressedSend is a carrier whose message names its target, so one connection can send a request
// to a FUNCTIONAL address and receive the answer on its physical one: DoIP (doip.DoipClient
// send_to), where the target address is a field of the diagnostic message.
pub interface AddressedSend {
mut:
	send_to(target u32, data []u8) !
}

// functional_addressed sends `req` once to the functional address `target` through `via` and
// collects the answer on `c`'s channel — the same connection, so ONE server's answer (on DoIP, the
// entity the connection is routed to). Outcomes, the drain before the send, answer_to and the P2*
// rule are those of `functional`; `window_ms` bounds the first answer. A request has no Single
// Frame limit here: the carrier frames it whole.
pub fn functional_addressed(mut c Client, mut via AddressedSend, target u32, req []u8, window_ms int) !FunctionalReply {
	if req.len == 0 {
		return error('empty UDS request')
	}
	c.drain_queued(req[0])!
	via.send_to(target, req)!
	sw := time.new_stopwatch()
	mut deadline := i64(window_ms)
	mut pended := false
	for {
		left := deadline - sw.elapsed().milliseconds()
		if left <= 0 {
			break
		}
		resp := c.ch.recv(int(left)) or {
			if is_silence(err.msg()) {
				continue
			}
			return FunctionalReply{
				outcome: .failed
				pended:  pended
				err:     err.msg()
			}
		}
		verdict, reply := heard(mut c, req, resp, pended)
		match verdict {
			.settled {
				return reply
			}
			.pending {
				pended = true
				deadline = c.pending_deadline(sw.elapsed().milliseconds())
			}
			.stale {}
		}
	}
	return FunctionalReply{
		outcome: if pended { .pending } else { .silent }
		pended:  pended
	}
}
