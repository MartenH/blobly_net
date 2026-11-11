// The transport protocol (J1939-21), SENT: a parameter group of 9..1785 bytes broadcast as one
// TP.CM BAM and its TP.DT packets (#619). The one segmenter every send path asks — a simulated
// node, a generator, a background sender, a script's message send — so they cannot disagree
// about what a long J1939 message is on the wire. Destination-specific RTS/CTS is not sent here.
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
// row and wire frame it, transport.frame_out) — its BAM (bam_frames).
pub fn message_frames(f transport.CanFrame, declared bool, fd bool) ![]transport.CanFrame {
	if !declared || fd || f.data.len < tp_min_size {
		return [f]
	}
	return bam_frames(f)!
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
		return error('PGN 0x${id.pgn():04X} to 0x${id.ps:02X}: a message to one node goes by RTS/CTS, which is not sent; a BAM is to the global address (0xFF)')
	}
	group := id.pgn()
	packets := packets_for(n)
	mut out := []transport.CanFrame{cap: packets + 1}
	out << classic(compose(tp_priority, pgn_tp_cm, addr_global, id.sa), [cm_bam, u8(n & 0xFF),
		u8(n >> 8), u8(packets), 0xFF, u8(group & 0xFF), u8((group >> 8) & 0xFF), u8((group >> 16) & 0xFF)])
	dt_id := compose(tp_priority, pgn_tp_dt, addr_global, id.sa)
	for k in 0 .. packets {
		mut d := []u8{len: 8, init: 0xFF}
		d[0] = u8(k + 1)
		for i in 0 .. 7 {
			at := k * 7 + i
			if at < n {
				d[i + 1] = f.data[at]
			}
		}
		out << classic(dt_id, d)
	}
	return out
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
// J1939: the one frame, or its BAM paced bam_gap_ms apart (send_paced, `stop` asked between frames)
// on its source address's lane of the bus's wire (transport.wire_of) — decided by the frame as
// `bus` puts it on the wire (transport.frame_out). The blocking form of message_frames, for a
// sender that owns its bus and its thread.
pub fn send_message(mut bus transport.Bus, f transport.CanFrame, declared bool, stop fn () bool) ! {
	frames := message_frames(f, declared, transport.frame_out(bus, f).fd)!
	if frames.len == 1 {
		bus.send(frames[0])!
		return
	}
	send_paced(mut bus, frames, bam_gap_ms, lane_key(transport.wire_of(bus), sa_of(frames)),
		stop)!
}

// send_paced sends `frames` on `bus`, the first once `lane` is free of any other sender's
// transfer (lanes.v; '' none) and each next `gap_ms` after the one before, waiting in slices that
// ask `stop` (nil: never stopped): an error for a refused send, a stop, or a lane lost to a stall
// past lane_hold_ms, the rest unsent. A blocking send, for a path that owns its bus and its thread.
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
			if lane_take(lane, me, now, hold_ns()) {
				break
			}
			if k > 0 {
				return error('transport frame ${k + 1} of ${frames.len}: another transfer took the source address after a stall')
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
// time is followed by the next `gap_ms` after it was sent, never sooner.
pub struct Pacer {
pub mut:
	gap_ms f64 = bam_gap_ms
mut:
	owner u64 // its claims' identity (lanes.v), taken at its first claim
	queue []Transfer
	ready map[string]f64 // a lane's earliest next send
}

struct Transfer {
	lane string // the pacer's own: the process-wide one, else the source address
	key  string // the process-wide lane, '' none
	pgn  u32
mut:
	tag    int
	frames []transport.CanFrame
	next   int
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
	p.queue << Transfer{
		lane:   lane
		key:    key
		pgn:    group
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

// pump hands `send` each lane's next frame that is due by `now_ms`, with its transfer's tag — a
// transfer's first only once its lane is free of other senders' transfers; a frame `send` refuses
// ends its transfer, the rest unsent.
pub fn (mut p Pacer) pump(now_ms f64, send fn (f transport.CanFrame, tag int) bool) {
	if p.owner == 0 {
		p.owner = lane_owner()
	}
	gap := u64(p.gap_ms * f64(time.millisecond))
	mut served := map[string]bool{}
	mut i := 0
	for i < p.queue.len {
		lane := p.queue[i].lane
		if served[lane] || now_ms < (p.ready[lane] or { now_ms }) {
			served[lane] = true
			i++
			continue
		}
		served[lane] = true
		mut t := &p.queue[i]
		if !lane_take(t.key, p.owner, time.sys_mono_now(), hold_ns()) {
			i++
			continue
		}
		ok := send(t.frames[t.next], t.tag)
		t.next++
		p.ready[lane] = now_ms + p.gap_ms
		if !ok || t.next >= t.frames.len {
			lane_free(t.key, p.owner, time.sys_mono_now(), gap)
			p.queue.delete(i)
			continue
		}
		i++
	}
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
