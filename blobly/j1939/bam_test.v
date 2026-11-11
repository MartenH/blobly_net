module j1939

import time
import blobly.transport

// long_msg is a message of `n` bytes at `id`, each byte its index.
fn long_msg(id u32, n int) transport.CanFrame {
	mut d := []u8{len: n}
	for i in 0 .. n {
		d[i] = u8(i * 7 + 3)
	}
	return transport.CanFrame{
		id:       id
		extended: true
		data:     d
	}
}

// rejoined feeds `frames` to the Reassembler, `gap` ms apart, and returns what it completed and
// every fault it said.
fn rejoined(frames []transport.CanFrame, gap f64) ([]Assembled, []Fault) {
	mut r := Reassembler{}
	mut done := []Assembled{}
	mut faults := []Fault{}
	for k, f in frames {
		ev := r.feed(f, f64(k) * gap)
		done << ev.done
		faults << ev.faults
	}
	return done, faults
}

fn test_a_bam_is_what_the_reassembler_rejoins_at_every_size() {
	for n in [9, 13, 14, 15, 20, 64, 65, 700, 1784, 1785] {
		msg := long_msg(compose(6, 0xFF10, addr_global, 0x21), n)
		frames := bam_frames(msg) or { panic(err) }
		assert frames.len == packets_for(n) + 1
		for f in frames {
			assert tp_shaped(f) && f.format_stated && !f.fd
			assert decompose(f.id).priority == tp_priority && decompose(f.id).sa == 0x21
		}
		done, faults := rejoined(frames, bam_gap_ms)
		assert faults.len == 0, '${n}: ${faults}'
		assert done.len == 1
		assert done[0].bam && done[0].pgn == 0xFF10 && done[0].sa == 0x21 && done[0].da == addr_global
		assert done[0].data == msg.data
	}
}

fn test_the_last_packet_is_padded_with_ff() {
	msg := long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)
	frames := bam_frames(msg) or { panic(err) }
	assert frames[0].data == [cm_bam, 20, 0, 3, 0xFF, 0x10, 0xFF, 0x00]
	assert frames[3].data[0] == 3
	assert frames[3].data[1..7] == msg.data[14..20] && frames[3].data[7] == 0xFF
	assert frames.map(decompose(it.id).pgn()) == [pgn_tp_cm, pgn_tp_dt, pgn_tp_dt, pgn_tp_dt]
}

fn test_a_pdu1_group_is_broadcast_only_to_the_global_address() {
	// PGN 0xEF00 (PDU1): to 0xFF a BAM carrying the group with its low byte zero
	frames := bam_frames(long_msg(compose(6, 0xEF00, addr_global, 0x10), 12)) or { panic(err) }
	done, _ := rejoined(frames, bam_gap_ms)
	assert done.len == 1 && done[0].pgn == 0xEF00
	// to one node it is an RTS/CTS connection, not a BAM
	if _ := bam_frames(long_msg(compose(6, 0xEF00, 0x05, 0x10), 12)) {
		assert false
	} else {
		assert err.msg().contains('RTS/CTS')
	}
}

fn test_message_frames_decides_one_frame_or_a_bam() {
	msg := long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)
	assert (message_frames(msg, false, false) or { panic(err) }) == [msg] // not declared J1939
	assert (message_frames(msg, true, true) or { panic(err) }) == [msg] // goes out CAN-FD
	short := long_msg(compose(6, 0xFF10, addr_global, 0x21), 8)
	assert (message_frames(short, true, false) or { panic(err) }) == [short]
	assert (message_frames(msg, true, false) or { panic(err) }).len == 4
	if _ := message_frames(long_msg(compose(6, 0xFF10, addr_global, 0x21), 1786), true, false) {
		assert false
	}
	if _ := message_frames(transport.CanFrame{ id: 0x123, data: []u8{len: 12} }, true,
		false)
	{
		assert false
	}
}

fn test_the_pacer_spaces_frames_and_serialises_a_lane() {
	a := bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)) or { panic(err) }
	b := bam_frames(long_msg(compose(6, 0xFF11, addr_global, 0x21), 10)) or { panic(err) }
	mut p := Pacer{}
	p.add('pacer_spaces', a, 1)
	p.add('pacer_spaces', b, 2)
	mut out := &Sent{}
	for t := 0; t <= 600; t += 5 {
		now := f64(t)
		p.pump(now, fn [mut out, now] (f transport.CanFrame, tag int) bool {
			out.frames << f
			out.at << now
			out.tags << tag
			return true
		})
	}
	assert p.pending() == 0
	assert out.frames.len == a.len + b.len
	assert out.tags == [1, 1, 1, 1, 2, 2, 2]
	for k in 1 .. out.at.len {
		assert out.at[k] - out.at[k - 1] >= bam_gap_ms
	}
	mut r := Reassembler{}
	mut done := []Assembled{}
	for k, f in out.frames {
		ev := r.feed(f, out.at[k])
		assert ev.faults.len == 0
		done << ev.done
	}
	assert done.map(it.pgn) == [u32(0xFF10), 0xFF11]
}

@[heap]
struct Sent {
mut:
	frames []transport.CanFrame
	at     []f64
	tags   []int
}

fn test_the_pacer_keeps_the_latest_of_a_waiting_message_and_ends_a_refused_transfer() {
	first := bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)) or { panic(err) }
	other := bam_frames(long_msg(compose(6, 0xFF11, addr_global, 0x21), 20)) or { panic(err) }
	mut p := Pacer{}
	p.add('pacer_latest', first, 1)
	p.add('pacer_latest', other, 2)
	p.add('pacer_latest', other, 3) // replaces the waiting one
	assert p.pending() == 2
	// another lane goes alongside
	p.add('pacer_latest', bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x22), 9)) or {
		panic(err)
	}, 4)
	mut out := &Sent{}
	p.pump(0, fn [mut out] (f transport.CanFrame, tag int) bool {
		out.tags << tag
		return tag != 1 // the first transfer's announcement is refused
	})
	assert out.tags == [1, 4]
	assert p.pending() == 2
	for t := 50; t <= 400; t += 50 {
		p.pump(f64(t), fn [mut out] (f transport.CanFrame, tag int) bool {
			out.tags << tag
			return true
		})
	}
	assert out.tags == [1, 4, 3, 4, 3, 4, 3, 3]
}

fn test_send_paced_puts_a_bam_on_a_bus() {
	msg := long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)
	frames := bam_frames(msg) or { panic(err) }
	mut rx := transport.open('inproc:bam_paced') or { panic(err) }
	mut tx := transport.open('inproc:bam_paced') or { panic(err) }
	send_paced(mut tx, frames, 2, '', unsafe { nil }) or { panic(err) }
	mut got := []transport.CanFrame{}
	for _ in 0 .. frames.len {
		got << rx.recv(500) or { panic(err) }
	}
	done, faults := rejoined(got, 2)
	assert faults.len == 0 && done.len == 1 && done[0].data == msg.data
	// a stop ends it between frames
	send_paced(mut tx, frames, 2, '', fn () bool {
		return true
	}) or {
		assert err.msg().contains('stopped after 1')
		tx.close()
		rx.close()
		return
	}
	assert false
}

fn test_abandon_drops_a_tags_transfers() {
	a := bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)) or { panic(err) }
	mut p := Pacer{}
	p.add('', a, 1)
	p.add('pacer_abandon', a, 2)
	p.abandon(1)
	assert p.pending() == 1
}

fn test_a_j1939_message_stated_classic_keeps_its_length_for_its_bam() {
	msg := long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)
	f := stated(.classic, msg, true) or { panic(err) }
	assert f.format_stated && !f.fd && f.data.len == 20
	assert (message_frames(f, true, false) or { panic(err) }).len == 4
	if _ := stated(.classic, msg, false) {
		assert false, 'any other message stated classic carries 8 bytes'
	}
	assert (stated(.fd, msg, true) or { panic(err) }).fd
}

// two senders of one source address on one wire — a blocking one on its thread and a pacer — take
// turns: one BAM at a time, each rejoined whole
fn test_senders_of_one_source_address_on_a_wire_take_turns() {
	wire := 'inproc:bam_lanes'
	a := bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x21), 60)) or { panic(err) }
	b := bam_frames(long_msg(compose(6, 0xFF11, addr_global, 0x21), 60)) or { panic(err) }
	mut rx := transport.open(wire) or { panic(err) }
	defer {
		rx.close()
	}
	mut p := Pacer{
		gap_ms: 2
	}
	p.add(wire, b, 1)
	// the pacer's first frame claims the lane before the thread starts
	p.pump(f64(time.ticks()), fn (f transport.CanFrame, tag int) bool {
		mut tx := transport.open('inproc:bam_lanes') or { return false }
		tx.send(f) or { return false }
		tx.close()
		return true
	})
	th := spawn fn (wire string, frames []transport.CanFrame) string {
		mut tx := transport.open(wire) or { return err.msg() }
		defer {
			tx.close()
		}
		send_paced(mut tx, frames, 2, lane_key(wire, 0x21), unsafe { nil }) or { return err.msg() }
		return ''
	}(wire, a)
	for p.pending() > 0 {
		p.pump(f64(time.ticks()), fn (f transport.CanFrame, tag int) bool {
			mut tx := transport.open('inproc:bam_lanes') or { return false }
			tx.send(f) or { return false }
			tx.close()
			return true
		})
		time.sleep(time.millisecond)
	}
	assert th.wait() == ''
	mut got := []transport.CanFrame{}
	for _ in 0 .. a.len + b.len {
		got << rx.recv(500) or { panic(err) }
	}
	done, faults := rejoined(got, 2)
	assert faults.len == 0
	assert done.map(it.pgn) == [u32(0xFF11), 0xFF10]
	// a lane of another address, or of another wire, is not held by this one's
	assert lane_take(lane_key(wire, 0x22), lane_owner(), time.sys_mono_now(), hold_ns())
	assert lane_key(wire, 0x21) != lane_key('inproc:bam_lanes2', 0x21)
}

// a transfer's lane stays claimed until its last frame is reported sent, not when it is handed out
fn test_the_lane_is_held_until_the_last_frame_is_settled() {
	wire := 'inproc:bam_settle'
	a := bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x21), 9)) or { panic(err) }
	mut p := Pacer{}
	p.add(wire, a, 1)
	first := p.take(0)
	assert first.len == 1 && !first[0].last
	assert !p.settle(first[0], true, 0)
	mid := p.take(50)
	assert mid.len == 1 && !mid[0].last
	assert !p.settle(mid[0], true, 50)
	last := p.take(100)
	assert last.len == 1 && last[0].last
	assert p.has(1), 'in flight until reported'
	other := lane_owner()
	key := lane_key(wire, 0x21)
	assert !lane_take(key, other, time.sys_mono_now(), hold_ns()), 'held while the last frame is out'
	assert p.take(500).len == 0, 'nothing more of the lane while its frame is unreported'
	assert p.settle(last[0], true, 500)
	assert !p.has(1)
	assert lane_take(key, other, time.sys_mono_now() + u64(bam_gap_ms) * u64(time.millisecond),
		hold_ns())
}

// a transfer whose source address another sender took after a stall is dropped, never resumed
// without its announcement
fn test_a_transfer_whose_lane_was_lost_is_dropped() {
	wire := 'inproc:bam_lost'
	a := bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x21), 20)) or { panic(err) }
	mut p := Pacer{}
	p.add(wire, a, 1)
	d := p.take(0)
	assert d.len == 1
	p.settle(d[0], true, 0)
	// another sender claimed it during the stall, and its claim has since lapsed
	key := lane_key(wire, 0x21)
	thief := lane_owner()
	lock tp_lanes {
		tp_lanes.by[key] = Lane{
			owner: thief
			until: time.sys_mono_now() - 1
		}
	}
	assert p.take(1000).len == 0
	assert p.pending() == 0
	// so is one whose own claim lapsed
	mut q := Pacer{}
	q.add(wire, a, 2)
	e := q.take(0)
	q.settle(e[0], true, 0)
	lock tp_lanes {
		tp_lanes.by[key] = Lane{
			owner: q.owner
			until: time.sys_mono_now() - 1
		}
	}
	assert q.take(1000).len == 0
	assert q.pending() == 0
}

// a lane's next frame — of its transfer, or of the next transfer — is a gap after the send before
// it returned, not after that frame was handed out
fn test_the_gap_runs_from_when_a_send_returned() {
	a := bam_frames(long_msg(compose(6, 0xFF10, addr_global, 0x23), 9)) or { panic(err) }
	b := bam_frames(long_msg(compose(6, 0xFF11, addr_global, 0x23), 9)) or { panic(err) }
	mut p := Pacer{}
	p.add('inproc:bam_gap_after', a, 1)
	p.add('inproc:bam_gap_after', b, 2)
	first := p.take(0)
	assert first.len == 1
	assert !p.settle(first[0], true, 100), 'a write that took 100 ms'
	assert p.take(60).len == 0, 'not a gap after it was handed out'
	assert p.take(149).len == 0
	mid := p.take(150)
	assert mid.len == 1
	assert !p.settle(mid[0], true, 150)
	last := p.take(200)
	assert last.len == 1 && last[0].last
	assert p.settle(last[0], true, 300)
	assert p.take(250).len == 0, 'the next transfer waits a gap after the last frame returned'
	assert p.take(349).len == 0
	next := p.take(350)
	assert next.len == 1 && next[0].tag == 2
	assert !p.settle(next[0], true, 350)
	p.abandon(2)
}
