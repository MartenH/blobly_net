module isotp

import blobly.transport
import time

fn test_stmin_code_reads_whole_milliseconds_and_tenths() {
	assert stmin_code(0)! == 0x00
	assert stmin_code(5)! == 0x05
	assert stmin_code(127)! == 0x7F
	assert stmin_code(0.1)! == 0xF1
	assert stmin_code(0.5)! == 0xF5
	assert stmin_code(0.9)! == 0xF9
	for bad in [f64(-1), 128, 1.5, 0.05, 0.95, 0.25] {
		if c := stmin_code(bad) {
			assert false, '${bad} read as 0x${c:02X}'
		}
	}
	// stmin_micros reads every code back to what was stated
	for ms in [f64(0), 1, 20, 127, 0.1, 0.3, 0.9] {
		s := settings_of(0, 0, ms)!
		assert s.stmin_ms() == ms
	}
}

fn test_settings_of_checks_padding_and_block_size() {
	assert settings_of(0, 0, 0)!.is_default()
	s := settings_of(0xAA, 8, 5)!
	assert s.padded && s.pad == 0xAA && s.block_size == 8 && s.stmin == 5
	assert s.padding() == 0xAA
	none_ := settings_of(no_padding, 0, 0)!
	assert !none_.padded && none_.padding() == no_padding
	for p in [i64(-2), 256] {
		if _ := settings_of(p, 0, 0) {
			assert false, 'padding ${p} taken'
		}
	}
	for bs in [i64(-1), 256] {
		if _ := settings_of(0, bs, 0) {
			assert false, 'block_size ${bs} taken'
		}
	}
}

fn test_frames_carry_the_padding_byte_or_none() {
	mut peer := transport.open('inproc:isotp-pad') or { panic(err) }
	mut ch := open_software('inproc:isotp-pad', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.settings = settings_of(0xAA, 0, 0)!
	ch.send([u8(1), 2])!
	f := next_on(mut peer, 0x7E0, 1000) or { panic('no Single Frame') }
	assert f.data == [u8(0x02), 1, 2, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA]
	ch.settings = settings_of(no_padding, 0, 0)!
	ch.send([u8(1), 2])!
	g := next_on(mut peer, 0x7E0, 1000) or { panic('no Single Frame') }
	assert g.data == [u8(0x02), 1, 2]
	ch.close()
	peer.close()
}

// Received is a recv running on its own thread.
struct Received {
mut:
	ch  &SoftChannel = unsafe { nil }
	got []u8
	err string
}

fn (mut r Received) run() {
	r.got = r.ch.recv(5000) or {
		r.err = err.msg()
		return
	}
}

// As a receiver the channel announces its block size and STmin, unpadded when so set, and sends
// the next Flow Control after each block: a peer sending as ISO 15765-2 has it checks both.
fn test_the_receiver_announces_its_flow_control_and_paces_blocks() {
	mut peer := transport.open('inproc:isotp-rx-fc') or { panic(err) }
	mut ch := open_software('inproc:isotp-rx-fc', 0x7E8, 0x7E0, false) or { panic(err) }
	ch.settings = settings_of(no_padding, 2, 0.5)!
	// 34 bytes: 6 in the First Frame, then four Consecutive Frames of 7, in two blocks of 2
	want := []u8{len: 34, init: u8(index)}
	mut r := &Received{
		ch: ch
	}
	peer.send(transport.CanFrame{ id: 0x7E0, data: [u8(0x10), 34, 0, 1, 2, 3, 4, 5] })!
	t := spawn r.run()
	mut sn := u8(1)
	mut off := 6
	for block in 0 .. 2 {
		fc := next_on(mut peer, 0x7E8, 2000) or { panic('no Flow Control before block ${block}') }
		assert fc.data == [u8(0x30), 2, 0xF5]
		for _ in 0 .. 2 {
			peer.send(cf_of(0x7E0, sn, want, off))!
			sn++
			off += 7
		}
	}
	t.wait()
	assert r.err == ''
	assert r.got == want
	// no Flow Control after the last block
	if extra := next_on(mut peer, 0x7E8, 50) {
		assert false, 'a Flow Control after the transfer ended: ${extra.data}'
	}
	ch.close()
	peer.close()
}

// A block size changed while a transfer waits between receives applies from the next Flow
// Control: the sender is following the one already sent, so the current block ends where it said.
fn test_a_changed_block_size_waits_for_the_next_flow_control() {
	mut peer := transport.open('inproc:isotp-rx-bs') or { panic(err) }
	mut ch := open_software('inproc:isotp-rx-bs', 0x7E8, 0x7E0, false) or { panic(err) }
	ch.settings = settings_of(no_padding, 1, 0)!
	want := []u8{len: 34, init: u8(index + 7)}
	peer.send(transport.CanFrame{ id: 0x7E0, data: [u8(0x10), 34, 7, 8, 9, 10, 11, 12] })!
	// the receive answers the First Frame with BS=1 and is cut by its deadline, the transfer kept
	if got := ch.recv(50) {
		assert false, 'a whole PDU from a First Frame alone: ${got}'
	}
	fc := next_on(mut peer, 0x7E8, 1000) or { panic('no Flow Control for the First Frame') }
	assert fc.data == [u8(0x30), 1, 0]
	ch.settings = settings_of(no_padding, 2, 0)!
	// the sender keeps BS=1: one Consecutive Frame, then it waits for a Flow Control
	peer.send(cf_of(0x7E0, 1, want, 6))!
	mut r := &Received{
		ch: ch
	}
	t := spawn r.run()
	mut sn := u8(2)
	mut off := 13
	for block in 0 .. 2 {
		next := next_on(mut peer, 0x7E8, 2000) or { panic('no Flow Control before block ${block}') }
		assert next.data == [u8(0x30), 2, 0]
		for _ in 0 .. 2 {
			if off >= want.len {
				break
			}
			peer.send(cf_of(0x7E0, sn, want, off))!
			sn++
			off += 7
		}
	}
	t.wait()
	assert r.err == ''
	assert r.got == want
	ch.close()
	peer.close()
}

// cf_of is Consecutive Frame `sn` on `id`, carrying the next up-to-seven bytes of `pdu` from
// `off`: the last one short, unpadded.
fn cf_of(id u32, sn u8, pdu []u8, off int) transport.CanFrame {
	end := if off + 7 < pdu.len { off + 7 } else { pdu.len }
	mut data := [u8(0x20 | (sn & 0x0F))]
	data << pdu[off..end]
	return transport.CanFrame{
		id:   id
		data: data
	}
}

// Two channels: the sender keeps the receiver's STmin between Consecutive Frames and waits for a
// Flow Control after each block it asked for.
fn test_a_sender_keeps_what_the_receiver_announced() {
	mut tap := transport.open('inproc:isotp-rx-e2e') or { panic(err) }
	mut rx := open_software('inproc:isotp-rx-e2e', 0x7E8, 0x7E0, false) or { panic(err) }
	mut tx := open_software('inproc:isotp-rx-e2e', 0x7E0, 0x7E8, false) or { panic(err) }
	rx.settings = settings_of(0xCC, 2, 5)!
	want := []u8{len: 34, init: u8(index * 3)}
	mut r := &Received{
		ch: rx
	}
	t := spawn r.run()
	t0 := time.sys_mono_now()
	tx.send(want)!
	elapsed_ms := (time.sys_mono_now() - t0) / 1_000_000
	t.wait()
	assert r.err == ''
	assert r.got == want
	// four Consecutive Frames, three gaps of at least 5 ms
	assert elapsed_ms >= 15, 'sent in ${elapsed_ms} ms'
	mut kinds := []string{}
	for {
		f := tap.recv(0) or { break }
		match f.data[0] & 0xF0 {
			0x10 { kinds << 'FF' }
			0x20 { kinds << 'CF' }
			0x30 {
				assert f.data == [u8(0x30), 2, 5, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC]
				kinds << 'FC'
			}
			else {}
		}
	}
	assert kinds == ['FF', 'FC', 'CF', 'CF', 'FC', 'CF', 'CF']
	rx.close()
	tx.close()
	tap.close()
}

// next_on is the next frame on `id` within `timeout_ms`, past the others the bus carries.
fn next_on(mut bus transport.Bus, id u32, timeout_ms int) ?transport.CanFrame {
	deadline := time.ticks() + i64(timeout_ms)
	for {
		rem := deadline - time.ticks()
		f := bus.recv(int(if rem > 0 { rem } else { i64(0) })) or { return none }
		if f.id == id {
			return f
		}
	}
	return none
}
