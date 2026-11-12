// The transport protocol (J1939-21), SENT: a parameter group of 9..1785 bytes broadcast as one
// TP.CM BAM and its TP.DT packets (#619). The one segmenter every send path asks — a simulated
// node, a generator, a background sender, a script's message send — so they cannot disagree
// about what a long J1939 message is on the wire. A message to one node is an RTS/CTS connection
// (conn.v), which send_message opens.
module j1939

import time
import blobly.transport

// bam_gap_ms is the time between a BAM's frames: J1939-21 lets a sender space the packets of a
// broadcast 50 to 200 ms apart, and this is the shortest.
pub const bam_gap_ms = 50

// tp_priority is the priority of the frames carrying a transfer, J1939-21's default for TP.CM
// and TP.DT.
pub const tp_priority = u8(7)

// message_frames is what a message's frame `f` goes out as: `f` alone, or — a message its database
// declares J1939 (`declared`) of more than 8 bytes, going out classic (`fd` false: the frame as its
// row and wire frame it, transport.frame_out) — its BAM (bam_frames); refused for one to a single
// node, which is a connection (needs_connection) and no set of frames of its own.
pub fn message_frames(f transport.CanFrame, declared bool, fd bool) ![]transport.CanFrame {
	if goes_alone(f, declared, fd) {
		return [f]
	}
	return bam_frames(f)!
}

// goes_alone is whether a message's frame `f` goes out as itself: not declared J1939, going out
// CAN-FD, or short enough for one classic frame.
fn goes_alone(f transport.CanFrame, declared bool, fd bool) bool {
	return !declared || fd || f.data.len < tp_min_size
}

// stated is a message's frame `f` with format `ff` stated (FrameFormat.stamp), but for a message
// its database declares J1939 (`declared`) of more than 8 bytes stated classic, which keeps its
// length: it goes out as a BAM, whose frames are classic.
pub fn stated(ff transport.FrameFormat, f transport.CanFrame, declared bool) !transport.CanFrame {
	if declared && ff == .classic && f.data.len >= tp_min_size {
		return transport.CanFrame{
			...f
			fd:            false
			brs:           false
			format_stated: true
		}
	}
	return ff.stamp(f)!
}

// bam_frames is the BAM a node sends for the parameter group in single-frame form `f` (its 29-bit
// id the group, source address and destination; its data the message): one TP.CM BAM to the global
// address, then packets_for(size) TP.DT frames numbered from 1, seven bytes each, the last padded
// with 0xFF — every frame classic at tp_priority from f's source address. Refused for an 11-bit id,
// a size outside 9..1785, and a PDU1 group addressed to one node, which goes by RTS/CTS.
pub fn bam_frames(f transport.CanFrame) ![]transport.CanFrame {
	if !f.extended {
		return error('0x${f.id:03X} is an 11-bit id: a J1939 parameter group has a 29-bit one')
	}
	n := f.data.len
	if n < tp_min_size || n > tp_max_size {
		return error('a transport-protocol message is ${tp_min_size} .. ${tp_max_size} bytes, not ${n}')
	}
	id := decompose(f.id)
	if id.da() != addr_global {
		return error('PGN 0x${id.pgn():04X} to 0x${id.ps:02X}: a message to one node goes by an RTS/CTS connection (send_message, a simulated node), not as a BAM, which is to the global address (0xFF)')
	}
	group := id.pgn()
	packets := packets_for(n)
	mut out := []transport.CanFrame{cap: packets + 1}
	out << classic(compose(tp_priority, pgn_tp_cm, addr_global, id.sa), [cm_bam, u8(n & 0xFF),
		u8(n >> 8), u8(packets), 0xFF, u8(group & 0xFF), u8((group >> 8) & 0xFF), u8((group >> 16) & 0xFF)])
	for k in 1 .. packets + 1 {
		out << dt_packet(id.sa, addr_global, f.data, k)
	}
	return out
}

// dt_packet is TP.DT packet `k` (from 1) of `data` from `sa` to `da`: its seven bytes, the last
// packet padded with 0xFF.
fn dt_packet(sa u8, da u8, data []u8, k int) transport.CanFrame {
	mut d := []u8{len: 8, init: 0xFF}
	d[0] = u8(k)
	for i in 0 .. 7 {
		at := (k - 1) * 7 + i
		if at < data.len {
			d[i + 1] = data[at]
		}
	}
	return classic(compose(tp_priority, pgn_tp_dt, da, sa), d)
}

// classic is a transport frame: stated classic, because J1939-21's transport protocol is classic
// CAN and a CAN-FD wire's declaration must not raise it.
fn classic(id u32, data []u8) transport.CanFrame {
	return transport.CanFrame{
		id:            id
		extended:      true
		data:          data
		format_stated: true
	}
}

// send_message sends a message's frame `f` on `bus`, `declared` whether its database declares it
// J1939: the one frame, its BAM paced bam_gap_ms apart (send_paced, `stop` asked between frames)
// on its source address's lane of the bus's wire (transport.wire_of), or — a message to one node
// (needs_connection) — its RTS/CTS connection (send_connection), decided by the frame as `bus`
// puts it on the wire (transport.frame_out). The blocking form of message_frames, for a sender
// that owns its bus and its thread.
pub fn send_message(mut bus transport.Bus, f transport.CanFrame, declared bool, stop fn () bool) ! {
	send_message_within(mut bus, f, declared, 0, stop)!
}

// send_message_within is send_message with a connection's answers each waited for `answer_ms`
// (0: T3, 1250 ms).
pub fn send_message_within(mut bus transport.Bus, f transport.CanFrame, declared bool, answer_ms int, stop fn () bool) ! {
	match message_shape(bus, f, declared) {
		.single {
			bus.send(f)!
		}
		.connection {
			send_connection(mut bus, f, answer_ms, stop)!
		}
		.bam {
			frames := bam_frames(f)!
			send_paced(mut bus, frames, bam_gap_ms, lane_key(transport.wire_of(bus), sa_of(frames)),
				stop)!
		}
	}
}

// Shape is how a message's frame goes out on a bus: as itself, as its BAM, or by an RTS/CTS
// connection.
pub enum Shape {
	single
	bam
	connection
}

// message_shape is how message frame `f` (`declared` whether its database declares it J1939) goes
// out on `bus`, decided by the frame as `bus` puts it on the wire (transport.frame_out): the one
// rule send_message and a loop that cannot block (a generator's wire) send by. It
// builds nothing, so a frame that goes out as itself costs no allocation to decide.
pub fn message_shape(bus transport.Bus, f transport.CanFrame, declared bool) Shape {
	fd := transport.frame_out(bus, f).fd
	if needs_connection(f, declared, fd) {
		return .connection
	}
	return if goes_alone(f, declared, fd) { .single } else { .bam }
}

// send_paced sends `frames` on `bus`, the first once `lane` is free of any other sender's
// transfer (lanes.v; '' none) and each next `gap_ms` after the one before, waiting in slices that
// ask `stop` (nil: never stopped): an error for a refused send, a stop, or a lane lost to a stall
// past lane_hold_ms (lane_keep), the rest unsent. A blocking send, for a path that owns its bus and its thread.
pub fn send_paced(mut bus transport.Bus, frames []transport.CanFrame, gap_ms int, lane string, stop fn () bool) ! {
	me := lane_owner()
	gap := u64(gap_ms) * u64(time.millisecond)
	defer {
		lane_free(lane, me, time.sys_mono_now(), gap)
	}
	mut last := u64(0)
	for k, f in frames {
		mut waited := false
		for {
			if (k > 0 || waited) && stop != unsafe { nil } && stop() {
				return error('stopped after ${k} of ${frames.len} transport frames')
			}
			now := time.sys_mono_now()
			if k > 0 && now < last + gap {
				left := time.Duration(i64(last + gap - now))
				time.sleep(if left < 20 * time.millisecond { left } else { 20 * time.millisecond })
				continue
			}
			if k > 0 {
				if lane_keep(lane, me, now, hold_ns()) {
					break
				}
				return error('transport frame ${k + 1} of ${frames.len}: the source address was lost after a stall')
			}
			if lane_take(lane, me, now, hold_ns()) {
				break
			}
			waited = true
			time.sleep(5 * time.millisecond)
		}
		bus.send(f) or { return error('transport frame ${k + 1} of ${frames.len}: ${err.msg()}') }
		last = time.sys_mono_now()
	}
}

// Pacer sends transfers' frames `gap_ms` apart on a loop that cannot wait between them (a
// simulation's, a generator's), a transfer at a time per LANE — a sender's source address on its
// wire, claimed process-wide (lanes.v), since J1939-21 lets a node have one broadcast in progress
// — the next starting `gap_ms` after the last frame of the one before. A frame later than its
// time is followed by the next `gap_ms` after its send returned, never sooner. A frame is handed
// out (take) and reported back once sent (settle, with the time its send returned); the lane stays
// claimed until the transfer's last frame is reported, and a transfer whose claim was lost in
// between is dropped.
pub struct Pacer {
pub mut:
	gap_ms f64 = bam_gap_ms
mut:
	owner   u64 // its claims' identity (lanes.v), taken at its first claim
	queue   []Transfer
	ready   map[string]f64 // a lane's earliest next send: gap_ms after its last send returned
	next_id u64
}

struct Transfer {
	lane string // the pacer's own: the process-wide one, else the source address
	key  string // the process-wide lane, '' none
	pgn  u32
mut:
	id     u64
	tag    int
	frames []transport.CanFrame
	next   int
	flying bool // a frame handed out and not yet reported
}

// Due is a frame a pacer hands out (take), to be reported back once its send returned (settle).
pub struct Due {
pub:
	frame transport.CanFrame
	tag   int  // its transfer's, as given to add
	last  bool // its transfer's last frame
	id    u64  // its transfer
}

// add queues a transfer's `frames` on its source address's lane of `wire` ('' a lane of this
// pacer's only), `tag` the caller's (handed back with each frame). A transfer of the same group
// still waiting to start on the lane is replaced, so a lane holds the latest of each message and a
// sender faster than its transfers cannot grow the queue.
pub fn (mut p Pacer) add(wire string, frames []transport.CanFrame, tag int) {
	if frames.len == 0 {
		return
	}
	key := lane_key(wire, sa_of(frames))
	lane := if key != '' { key } else { '#${sa_of(frames)}' }
	group := group_of(frames[0])
	for mut t in p.queue {
		if t.lane == lane && t.pgn == group && t.next == 0 {
			t.frames = frames
			t.tag = tag
			return
		}
	}
	p.next_id++
	p.queue << Transfer{
		lane:   lane
		key:    key
		pgn:    group
		id:     p.next_id
		tag:    tag
		frames: frames
	}
}

// group_of is the parameter group a transfer carries: a BAM's announced one, else the frame's own.
fn group_of(f transport.CanFrame) u32 {
	if cm := parse_cm(f.data) {
		return cm.pgn
	}
	return pgn(f.id)
}

// take hands out each lane's next frame that is due by `now_ms` — a transfer's first only once its
// lane is free of other senders' transfers, none while the lane's last frame is unreported — and
// drops a transfer in progress whose claim was lost (another sender took its source address after
// a stall, or the claim lapsed past lane_hold_ms), the rest of it unsent.
pub fn (mut p Pacer) take(now_ms f64) []Due {
	if p.owner == 0 {
		p.owner = lane_owner()
	}
	mut out := []Due{}
	mut served := map[string]bool{}
	mut i := 0
	for i < p.queue.len {
		lane := p.queue[i].lane
		if served[lane] || p.queue[i].flying || now_ms < (p.ready[lane] or { now_ms }) {
			served[lane] = true
			i++
			continue
		}
		served[lane] = true
		mut t := &p.queue[i]
		now := time.sys_mono_now()
		if t.next > 0 {
			if !lane_keep(t.key, p.owner, now, hold_ns()) {
				p.queue.delete(i)
				continue
			}
		} else if !lane_take(t.key, p.owner, now, hold_ns()) {
			i++
			continue
		}
		out << Due{
			frame: t.frames[t.next]
			tag:   t.tag
			last:  t.next + 1 >= t.frames.len
			id:    t.id
		}
		t.next++
		t.flying = true
		i++
	}
	return out
}

// settle reports whether frame `d` was sent (`ok`), its send having returned at `sent_ms` (take's
// clock), from which its lane's next frame — of this transfer or the next — is gap_ms away: a
// refused frame ends its transfer, the rest unsent, and so does its last frame sent — releasing
// its lane either way. True when this completed the transfer, every frame sent; false otherwise,
// and for a transfer abandoned or dropped meanwhile.
pub fn (mut p Pacer) settle(d Due, ok bool, sent_ms f64) bool {
	for i, mut t in p.queue {
		if t.id != d.id {
			continue
		}
		t.flying = false
		p.ready[t.lane] = sent_ms + p.gap_ms
		if ok && !d.last {
			return false
		}
		lane_free(t.key, p.owner, time.sys_mono_now(), u64(p.gap_ms * f64(time.millisecond)))
		p.queue.delete(i)
		return ok
	}
	return false
}

// next_ms is when take next has a frame to hand out, on take's clock at `now_ms`: the earliest
// of each lane's next transfer's time, gap_ms after its lane's last send and once the lane is free
// of any other sender's transfer; none while nothing is queued or every lane's frame is out.
pub fn (p Pacer) next_ms(now_ms f64) ?f64 {
	mut next := 0.0
	mut any := false
	mut seen := map[string]bool{}
	now_ns := time.sys_mono_now()
	for t in p.queue {
		if seen[t.lane] {
			continue
		}
		seen[t.lane] = true
		if t.flying {
			continue
		}
		mut at := p.ready[t.lane] or { now_ms }
		if t.next == 0 {
			free_at := lane_free_at(t.key, p.owner, now_ns)
			if free_at > now_ns {
				by := now_ms + f64(free_at - now_ns) / f64(time.millisecond)
				if by > at {
					at = by
				}
			}
		}
		if !any || at < next {
			next = at
			any = true
		}
	}
	if !any {
		return none
	}
	return next
}

// pump hands `send` each frame take gives out, with its transfer's tag, and settles it by what
// `send` answers (true: sent) at the time it returned (returned_ms): the tags of the transfers it
// completed.
pub fn (mut p Pacer) pump(now_ms f64, send fn (f transport.CanFrame, tag int) bool) []int {
	mut done := []int{}
	t0 := time.sys_mono_now()
	for d in p.take(now_ms) {
		sent := send(d.frame, d.tag)
		if p.settle(d, sent, returned_ms(now_ms, t0)) {
			done << d.tag
		}
	}
	return done
}

// returned_ms is the time now on the clock of `now_ms`, read at `t0` (the monotonic clock's ns):
// when a send settled after a take at `now_ms` returned, in whole milliseconds since the take, so a
// send that returned at once leaves a caller's own clock (a simulation stepped in ms) exact.
pub fn returned_ms(now_ms f64, t0 u64) f64 {
	return now_ms + f64((time.sys_mono_now() - t0) / u64(time.millisecond))
}

// abandon drops every transfer of `tag`, the rest of their frames unsent.
pub fn (mut p Pacer) abandon(tag int) {
	gap := u64(p.gap_ms * f64(time.millisecond))
	for t in p.queue {
		if t.tag == tag && t.next > 0 {
			lane_free(t.key, p.owner, time.sys_mono_now(), gap)
		}
	}
	p.queue = p.queue.filter(it.tag != tag)
}

// has says whether a transfer of `tag` is queued or in progress.
pub fn (p Pacer) has(tag int) bool {
	return p.queue.any(it.tag == tag)
}

// pending is the number of transfers queued or in progress.
pub fn (p Pacer) pending() int {
	return p.queue.len
}
