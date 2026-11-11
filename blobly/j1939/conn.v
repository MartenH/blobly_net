// The transport protocol (J1939-21), as a PEER: an RTS/CTS connection, the destination-specific
// form of a message of 9..1785 bytes (#620). Beside the reassembler, which only watches, and
// reading control frames through the same Cm and its field table:
//
//   Originator  sends the RTS, waits for a CTS, sends the packets it clears (a hold of zero
//               packets respected), waits for the end-of-message acknowledgement; aborts on a
//               timeout and reports an abort from the peer.
//   Responder   answers an RTS aimed at an address it holds: a CTS per window, then the
//               acknowledgement; aborts a connection whose packets stop.
//
// Both are pure state machines over the caller's millisecond clock: a frame in, the frames to send
// out, so a simulation's loop, a script's read and a blocking send (send_connection) drive one
// rule, and a test drives it with synthetic time.
module j1939

import time
import blobly.transport

// The J1939-21 waits: T1 between a connection's packets at the responder, T2 for the first packet
// after a CTS, T3 for the originator's CTS or acknowledgement after an RTS or a window's last
// packet, T4 for a new CTS after a hold.
pub const conn_t1_ms = 750
pub const conn_t2_ms = 1250
pub const conn_t3_ms = 1250
pub const conn_t4_ms = 1050

// conn_per_cts is the most packets this side's RTS lets one CTS clear: a window is written back to
// back, and a SocketCAN interface's queue is ten frames (txqueuelen) before a write is refused.
pub const conn_per_cts = u8(8)

// abort reasons this side sends (J1939-21; abort_reason names every one)
const abort_timeout = u8(3)
const abort_bad_sequence = u8(7)
const abort_duplicate = u8(8)
const abort_other = u8(250)

// ConnEnd is how a connection stands, or how it ended.
pub enum ConnEnd {
	open    // going on
	done    // the receiver acknowledged the whole message
	timeout // an answer did not come in time; this side aborted it
	aborted // the peer aborted it
	stopped // this side's caller ended it; aborted
	lost    // another sender in this process took its lane; nothing more sent
}

// ConnOut is what one step of a connection produced: frames to send now, in order, and where the
// connection stands, with `detail` in words when it ended otherwise than done.
pub struct ConnOut {
pub mut:
	frames []transport.CanFrame
	end    ConnEnd
	detail string
}

// ConnError is a connection that did not complete, for a blocking sender's caller.
pub struct ConnError {
	Error
pub:
	end    ConnEnd
	detail string
}

pub fn (e ConnError) msg() string {
	return e.detail
}

enum OrigState {
	idle
	wait_cts
	wait_ack
	ended
}

// Originator is one RTS/CTS connection this side sends: `data` of group `pgn` from `sa` to `da`.
pub struct Originator {
pub:
	pgn       u32
	sa        u8
	da        u8
	priority  u8
	data      []u8
	answer_ms f64    // the wait for each CTS and for the acknowledgement (T3 unless the caller says)
	lane      string // the process-wide claim of (wire, sa, da), '' none (lanes.v)
pub mut:
	tag string // the caller's, for its reports
mut:
	owner    u64
	state    OrigState
	deadline f64
	wait_ms  f64 // the wait the last step armed, which wrote restarts
	sent     int // the highest packet sent so far
}

// needs_connection says whether a message's frame `f` goes out as an RTS/CTS connection: a message
// its database declares J1939 (`declared`) of more than 8 bytes going out classic (`fd` false), its
// group PDU1 and addressed to one node (not the global address). Otherwise message_frames says how.
pub fn needs_connection(f transport.CanFrame, declared bool, fd bool) bool {
	if !declared || fd || !f.extended || f.data.len < tp_min_size {
		return false
	}
	id := decompose(f.id)
	return id.pdu1() && id.da() != addr_global
}

// connection_for is the connection that carries the parameter group in single-frame form `f`
// (its 29-bit id the group, destination and source; its data the message), on `wire` (its lane,
// '' none), each answer waited for `answer_ms` (0: T3). Refused for an 11-bit id, a size outside
// 9..1785, a broadcast or PDU2 group, and the null or global address at either end.
pub fn connection_for(f transport.CanFrame, wire string, answer_ms int) !Originator {
	if !f.extended {
		return error('0x${f.id:03X} is an 11-bit id: a J1939 parameter group has a 29-bit one')
	}
	n := f.data.len
	if n < tp_min_size || n > tp_max_size {
		return error('a transport-protocol message is ${tp_min_size} .. ${tp_max_size} bytes, not ${n}')
	}
	id := decompose(f.id)
	if !id.pdu1() || id.da() == addr_global {
		return error('PGN 0x${id.pgn():04X} is broadcast: an RTS/CTS connection has one destination, a broadcast goes as a BAM')
	}
	if id.da() == addr_null || id.sa == addr_null || id.sa == addr_global {
		return error('PGN 0x${id.pgn():04X} from 0x${id.sa:02X} to 0x${id.da():02X}: a connection runs between two node addresses')
	}
	if answer_ms < 0 {
		return error('an answer wait is a positive number of milliseconds, not ${answer_ms}')
	}
	return Originator{
		pgn:       id.pgn()
		sa:        id.sa
		da:        id.da()
		priority:  tp_priority
		data:      f.data.clone()
		answer_ms: if answer_ms > 0 { f64(answer_ms) } else { f64(conn_t3_ms) }
		lane:      conn_lane(wire, id.sa, id.da())
		owner:     lane_owner()
	}
}

// conn_lane is the process-wide lane of a connection from `sa` to `da` on `wire`: J1939-21 lets a
// pair have one connection at a time in each direction. '' for no wire.
pub fn conn_lane(wire string, sa u8, da u8) string {
	key := lane_key(wire, sa)
	return if key == '' { '' } else { '${key}>${da}' }
}

// packets is how many TP.DT frames carry the message.
pub fn (o Originator) packets() int {
	return packets_for(o.data.len)
}

// open says whether the connection is still going on.
pub fn (o Originator) open() bool {
	return o.state == .wait_cts || o.state == .wait_ack
}

// take_lane claims (or refreshes) the connection's lane at `now_ns` (sys_mono_now): false while
// another sender in this process has a connection from this source to this destination.
pub fn (o Originator) take_lane(now_ns u64) bool {
	hold := u64(o.answer_ms + conn_t4_ms) * u64(time.millisecond)
	return lane_take(o.lane, o.owner, now_ns, hold)
}

// free_lane lets the lane go at `now_ns`.
pub fn (o Originator) free_lane(now_ns u64) {
	lane_free(o.lane, o.owner, now_ns, 0)
}

// start opens the connection at `now_ms`: the RTS (at most conn_per_cts packets per CTS), and the
// wait for the first CTS.
pub fn (mut o Originator) start(now_ms f64) ConnOut {
	n := o.data.len
	o.state = .wait_cts
	o.arm(now_ms, o.answer_ms)
	return ConnOut{
		frames: [
			control_frame(o.sa, o.da, [cm_rts, u8(n & 0xFF), u8(n >> 8), u8(o.packets()), conn_per_cts,
				pgn_byte(o.pgn, 0), pgn_byte(o.pgn, 1), pgn_byte(o.pgn, 2)]),
		]
	}
}

// feed takes one frame read at `now_ms`: a CTS from the destination sends the packets it clears
// (none for a hold, which waits T4 for the next), its acknowledgement of this message ends the
// connection done, an abort of it from the destination ends it aborted. Anything else is not
// this connection's and changes nothing.
pub fn (mut o Originator) feed(f transport.CanFrame, now_ms f64) ConnOut {
	if !o.open() || !tp_shaped(f) {
		return ConnOut{}
	}
	id := decompose(f.id)
	if id.pgn() != pgn_tp_cm || id.sa != o.da || id.da() != o.sa {
		return ConnOut{}
	}
	cm := parse_cm_of(f) or { return ConnOut{} }
	if _ := cm.control_refusal() {
		return ConnOut{}
	}
	if cm.pgn != o.pgn {
		return ConnOut{}
	}
	match cm.ctrl {
		cm_cts {
			count := int(cm.raw[1])
			if count == 0 {
				o.state = .wait_cts
				o.arm(now_ms, conn_t4_ms)
				return ConnOut{}
			}
			if !cm.names_packet(o.packets()) {
				return ConnOut{}
			}
			first := int(cm.next_packet())
			last := if first + count - 1 < o.packets() { first + count - 1 } else { o.packets() }
			mut out := ConnOut{}
			for k in first .. last + 1 {
				out.frames << dt_packet(o.sa, o.da, o.data, k)
			}
			if last > o.sent {
				o.sent = last
			}
			o.state = if last == o.packets() { OrigState.wait_ack } else { OrigState.wait_cts }
			o.arm(now_ms, o.answer_ms)
			return out
		}
		// accepted once every packet has gone out, whether a retransmission was asked for since
		cm_eom_ack {
			if o.sent == o.packets() && cm.acknowledges(o.pgn, o.data.len, o.packets()) {
				o.state = .ended
				return ConnOut{
					end: .done
				}
			}
		}
		cm_abort {
			if cm.abort_role() != .originator {
				o.state = .ended
				return ConnOut{
					end:    .aborted
					detail: '${o.what()}: aborted by 0x${o.da:02X}: ${abort_reason(cm.reason())}'
				}
			}
		}
		else {}
	}
	return ConnOut{}
}

// wrote says the frames the last step returned went out by `now_ms`: the wait it armed runs from
// then, so a slow write of a window is not spent from the answer's time.
pub fn (mut o Originator) wrote(now_ms f64) {
	if o.open() {
		o.deadline = now_ms + o.wait_ms
	}
}

fn (mut o Originator) arm(now_ms f64, wait_ms f64) {
	o.wait_ms = wait_ms
	o.deadline = now_ms + wait_ms
}

// poll times the connection out at `now_ms`: past its wait it is aborted (reason 3).
pub fn (mut o Originator) poll(now_ms f64) ConnOut {
	if !o.open() || now_ms <= o.deadline {
		return ConnOut{}
	}
	waited := if o.state == .wait_ack { 'end-of-message acknowledgement' } else { 'CTS' }
	o.state = .ended
	return ConnOut{
		frames: [o.abort_frame(abort_timeout)]
		end:    .timeout
		detail: '${o.what()}: no ${waited} from 0x${o.da:02X} in time; aborted'
	}
}

// stop ends a connection still going on, aborted (reason 250, any other).
pub fn (mut o Originator) stop() ConnOut {
	if !o.open() {
		return ConnOut{}
	}
	o.state = .ended
	return ConnOut{
		frames: [o.abort_frame(abort_other)]
		end:    .stopped
		detail: '${o.what()}: stopped; aborted'
	}
}

// what names the connection, for a report.
fn (o Originator) what() string {
	return 'RTS/CTS PGN 0x${o.pgn:04X} (${o.data.len} bytes) from 0x${o.sa:02X} to 0x${o.da:02X}'
}

fn (o Originator) abort_frame(reason u8) transport.CanFrame {
	return abort_frame(o.sa, o.da, reason, .originator, o.pgn)
}

// Responder answers RTS/CTS connections aimed at `addresses`: a CTS for each window (as many
// packets as the RTS allows per CTS), the end-of-message acknowledgement once the last packet is
// in, an abort for a packet out of sequence (reason 7) or one already in (reason 8, as a listener
// beside it drops the transfer) or for packets that stop (reason 3: T2 after a CTS, T1 between
// packets). It keeps no data: a listener beside it rejoins the message.
pub struct Responder {
pub mut:
	addresses []u8
mut:
	conns map[u16]Answering
}

struct Answering {
	pgn     u32
	total   int
	packets int
	per_cts int
mut:
	next       int // the packet expected next
	window_end int // the last packet the CTS sent cleared
	deadline   f64
}

// open is how many connections it is answering.
pub fn (r Responder) open() int {
	return r.conns.len
}

// feed takes one frame read at `now_ms` and returns what to send in answer.
pub fn (mut r Responder) feed(f transport.CanFrame, now_ms f64) []transport.CanFrame {
	if r.addresses.len == 0 || !f.extended || f.rtr || f.fd {
		return []
	}
	id := decompose(f.id)
	me := id.da()
	if me !in r.addresses || id.sa == addr_null || id.sa == addr_global || id.sa == me {
		return []
	}
	k := skey(id.sa, me)
	if f.data.len != 8 {
		// a classic transport frame of another length ends the transfer it would belong to (a
		// packet, or a new announcement), as a listener beside it drops it: aborted (reason 250)
		p := id.pgn()
		ends := p == pgn_tp_dt
			|| (p == pgn_tp_cm && f.data.len > 0 && f.data[0] in [cm_rts, cm_bam])
		if ends {
			if c := r.conns[k] {
				r.conns.delete(k)
				return [abort_frame(me, id.sa, abort_other, .responder, c.pgn)]
			}
		}
		return []
	}
	match id.pgn() {
		pgn_tp_cm {
			cm := parse_cm_of(f) or { return [] }
			if cm.ctrl == cm_bam || (cm.ctrl == cm_rts && not_admitted(cm, id)) {
				// an announcement this side does not answer still ends the peer's transfer in
				// progress here, as a listener beside it drops it: aborted (reason 250)
				if c := r.conns[k] {
					r.conns.delete(k)
					return [abort_frame(me, id.sa, abort_other, .responder, c.pgn)]
				}
				return []
			}
			if cm.ctrl == cm_rts {
				per := int(cm.raw[4])
				mut c := Answering{
					pgn:     cm.pgn
					total:   cm.total
					packets: cm.packets
					per_cts: if per == 0xFF {
						255
					} else if per < 1 {
						1
					} else {
						per
					}
					next:    1
				}
				cts := c.clear(me, id.sa, now_ms)
				r.conns[k] = c
				return [cts]
			}
			if cm.ctrl == cm_abort && !refused(cm) {
				if c := r.conns[k] {
					if c.pgn == cm.pgn && cm.abort_role() != .responder {
						r.conns.delete(k)
					}
				}
			}
		}
		pgn_tp_dt {
			mut c := r.conns[k] or { return [] }
			seq := int(f.data[0])
			if seq != c.next {
				r.conns.delete(k)
				why := if seq >= 1 && seq < c.next { abort_duplicate } else { abort_bad_sequence }
				return [abort_frame(me, id.sa, why, .responder, c.pgn)]
			}
			c.next++
			c.deadline = now_ms + conn_t1_ms
			if seq == c.packets {
				r.conns.delete(k)
				return [
					control_frame(me, id.sa, [cm_eom_ack, u8(c.total & 0xFF), u8(c.total >> 8),
						u8(c.packets), 0xFF, pgn_byte(c.pgn, 0), pgn_byte(c.pgn, 1),
						pgn_byte(c.pgn, 2)]),
				]
			}
			if seq == c.window_end {
				cts := c.clear(me, id.sa, now_ms)
				r.conns[k] = c
				return [cts]
			}
			r.conns[k] = c
		}
		else {}
	}
	return []
}

// poll aborts (reason 3) every connection whose packets stopped by `now_ms`.
pub fn (mut r Responder) poll(now_ms f64) []transport.CanFrame {
	mut out := []transport.CanFrame{}
	mut gone := []u16{}
	for k, c in r.conns {
		if now_ms > c.deadline {
			gone << k
			out << abort_frame(u8(k & 0xFF), u8(k >> 8), abort_timeout, .responder, c.pgn)
		}
	}
	for k in gone {
		r.conns.delete(k)
	}
	return out
}

// stop aborts (reason 250) every connection it is answering, for an owner going away.
pub fn (mut r Responder) stop() []transport.CanFrame {
	mut out := []transport.CanFrame{}
	for k, c in r.conns {
		out << abort_frame(u8(k & 0xFF), u8(k >> 8), abort_other, .responder, c.pgn)
	}
	r.conns = map[u16]Answering{}
	return out
}

// abort_target says which of the connections one side sends (`sent`) and answers (`answered`) an
// abort `f` ends — true one answered, false one sent, none neither or no abort — by
// abort_targets_forward, the listeners' rule: with no role declared and the group open both ways,
// the one its sender originates.
pub fn abort_target(f transport.CanFrame, sent []Originator, answered Responder) ?bool {
	if !tp_shaped(f) || pgn(f.id) != pgn_tp_cm {
		return none
	}
	cm := parse_cm_of(f) or { return none }
	if cm.ctrl != cm_abort || refused(cm) {
		return none
	}
	id := decompose(f.id)
	mut fwd := ?AbortSide(none)
	if c := answered.conns[skey(id.sa, id.da())] {
		fwd = AbortSide{
			pgn: c.pgn
		}
	}
	mut rev := ?AbortSide(none)
	for o in sent {
		if o.open() && o.sa == id.da() && o.da == id.sa {
			rev = AbortSide{
				pgn: o.pgn
			}
		}
	}
	return abort_targets_forward(id, cm, fwd, rev)
}

fn not_admitted(cm Cm, id Id) bool {
	if _ := cm.admission(id) {
		return true
	}
	return false
}

fn refused(cm Cm) bool {
	if _ := cm.control_refusal() {
		return true
	}
	return false
}

// clear is the CTS for the next window, from `me` to the originator `to`, and the wait for its
// first packet (T2).
fn (mut c Answering) clear(me u8, to u8, now_ms f64) transport.CanFrame {
	left := c.packets - c.next + 1
	count := if c.per_cts < left { c.per_cts } else { left }
	c.window_end = c.next + count - 1
	c.deadline = now_ms + conn_t2_ms
	return control_frame(me, to, [cm_cts, u8(count), u8(c.next), 0xFF, 0xFF, pgn_byte(c.pgn, 0),
		pgn_byte(c.pgn, 1), pgn_byte(c.pgn, 2)])
}

// control_frame is a TP.CM frame from `sa` to `da`.
fn control_frame(sa u8, da u8, data []u8) transport.CanFrame {
	return classic(compose(tp_priority, pgn_tp_cm, da, sa), data)
}

// abort_frame is a Connection Abort from `sa` to `da` of group `pgn`, its sender's role declared.
fn abort_frame(sa u8, da u8, reason u8, role AbortRole, pgn u32) transport.CanFrame {
	r := if role == .originator { u8(0xFC) } else { u8(0xFD) }
	return control_frame(sa, da, [cm_abort, reason, r, 0xFF, 0xFF, pgn_byte(pgn, 0), pgn_byte(pgn, 1),
		pgn_byte(pgn, 2)])
}

fn pgn_byte(pgn u32, i int) u8 {
	return u8((pgn >> (8 * i)) & 0xFF)
}

// send_connection sends the parameter group in single-frame form `f` on `bus` as an RTS/CTS
// connection and returns once the destination has acknowledged it — each answer waited for
// `answer_ms` (0: T3), `stop` asked as it waits (nil: never), the connection's lane of the bus's
// wire claimed first. The answers are read from a handle of its own on that wire, opened for the
// connection, so whoever reads `bus` still gets every frame (a bus that names no wire is read
// itself). A ConnError when it did not complete: no answer in time, an abort from the
// destination, a stop; any other error is a send or receive that failed, the connection aborted.
pub fn send_connection(mut bus transport.Bus, f transport.CanFrame, answer_ms int, stop fn () bool) ! {
	wire := transport.wire_of(bus)
	mut o := connection_for(f, wire, answer_ms)!
	for !o.take_lane(time.sys_mono_now()) {
		if stop != unsafe { nil } && stop() {
			return ConnError{
				end:    .stopped
				detail: '${o.what()}: stopped before it began'
			}
		}
		time.sleep(5 * time.millisecond)
	}
	defer {
		o.free_lane(time.sys_mono_now())
	}
	// opened once the lane is ours, so no answer to the connection that held it is read as one
	mut rd := bus // copy: an interface value, the same bus
	if wire != '' {
		rd = transport.open(wire)!
	}
	defer {
		if wire != '' {
			rd.close()
		}
	}
	// subscribed before the RTS goes out, so its answer cannot pass the reader by
	rd.recv(0) or {}
	mut out := o.start(mono_ms())
	exchange: for {
		for x in out.frames {
			if out.end == .open && pgn(x.id) == pgn_tp_dt {
				// a stop between the packets of a window ends it there, its abort sent next
				if stop != unsafe { nil } && stop() {
					out = o.stop()
					continue exchange
				}
				if !o.take_lane(time.sys_mono_now()) {
					return o.lane_lost()
				}
			}
			bus.send(x) or {
				if o.open() {
					bus.send(o.abort_frame(abort_other)) or {}
				}
				return error('${o.what()}: ${err.msg()}')
			}
		}
		if out.frames.len > 0 {
			o.wrote(mono_ms())
		}
		match out.end {
			.open {}
			.done {
				return
			}
			else {
				return ConnError{
					end:    out.end
					detail: out.detail
				}
			}
		}
		if !o.take_lane(time.sys_mono_now()) {
			return o.lane_lost()
		}
		if stop != unsafe { nil } && stop() {
			out = o.stop()
			continue
		}
		out = o.poll(mono_ms())
		if out.end != .open {
			continue
		}
		fr := rd.recv(20) or {
			if err.msg() == 'timeout' {
				continue
			}
			bus.send(o.abort_frame(abort_other)) or {}
			return error('${o.what()}: ${err.msg()}')
		}
		out = o.feed(fr, mono_ms())
	}
}

// lane_lost is the end of a connection whose lane another sender took: nothing more is sent, its
// abort included, since that sender's connection runs between the same two addresses.
fn (o Originator) lane_lost() ConnError {
	return ConnError{
		end:    .lost
		detail: '${o.what()}: another sender in this process took its lane; nothing more sent'
	}
}

// mono_ms is the host's monotonic clock in milliseconds.
fn mono_ms() f64 {
	return f64(time.sys_mono_now()) / 1_000_000.0
}
