module isotp

import blobly.transport
import time

// FdReceived is a recv running on its own thread.
struct FdReceived {
mut:
	ch  &SoftChannel = unsafe { nil }
	got []u8
	err string
}

fn (mut r FdReceived) run() {
	r.got = r.ch.recv(5000) or {
		r.err = err.msg()
		return
	}
}

// on_id is the next frame on `id` within `timeout_ms`, past the others the bus carries.
fn on_id(mut bus transport.Bus, id u32, timeout_ms int) ?transport.CanFrame {
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

fn bytes_from(n int, first u8) []u8 {
	return []u8{len: n, init: u8(first + u8(index))}
}

fn test_settings_with_checks_tx_dl_and_format() {
	for dl in tx_dls {
		s := settings_with(0, 0, 0, dl, .wire)!
		assert s.tx_dl == u8(dl)
	}
	for bad in [i64(0), 7, 9, 10, 63, 65, 128] {
		if _ := settings_with(0, 0, 0, bad, .wire) {
			assert false, 'tx_dl ${bad} taken'
		}
	}
	// a classic frame carries at most 8 bytes, as FrameFormat.stamp refuses
	assert settings_with(0, 0, 0, 8, .classic)!.format == .classic
	if _ := settings_with(0, 0, 0, 12, .classic) {
		assert false, 'tx_dl 12 with classic taken'
	} else {
		assert err.msg().contains('classic frame carries at most 8 bytes')
	}
	assert !settings_with(0, 0, 0, 8, .fd)!.is_default()
	assert !settings_with(0, 0, 0, 64, .wire)!.is_default()
	// above 8 on a classic row only with an FD format stated
	s64 := settings_with(0, 0, 0, 64, .wire)!
	assert s64.row_refusal(true) == none
	assert (s64.row_refusal(false) or { '' }).contains('classic row')
	assert settings_with(0, 0, 0, 64, .fd)!.row_refusal(false) == none
	assert settings_of(0, 0, 0)!.row_refusal(false) == none
}

fn test_state_refuses_a_long_tx_dl_on_a_classic_row() {
	mut ch := open_software('inproc:isotp-fd-state', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.state(settings_with(0, 0, 0, 64, .wire)!) or {
		assert err.msg().contains('classic row')
		assert ch.settings.is_default()
		ch.row_fd = true
		ch.state(settings_with(0, 0, 0, 64, .wire)!)!
		assert ch.settings.tx_dl == 64
		ch.close()
		return
	}
	assert false, 'tx_dl 64 stated on a classic row'
}

// The channels below state fd: on a bare in-process bus no row declares CAN-FD.

// A Single Frame: up to 7 bytes the classic form in 8 bytes, past it the escape (0x00, then the
// length) padded up to the next CAN-FD length, up to TX_DL - 2 bytes.
fn test_single_frames_with_a_long_tx_dl() {
	mut peer := transport.open('inproc:isotp-fd-sf') or { panic(err) }
	mut ch := open_software('inproc:isotp-fd-sf', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.settings = settings_with(0xAA, 0, 0, 64, .fd)!
	ch.send(bytes_from(7, 1))!
	a := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert a.data == [u8(0x07), 1, 2, 3, 4, 5, 6, 7]
	ch.send(bytes_from(20, 1))!
	b := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	mut want := [u8(0x00), 20]
	want << bytes_from(20, 1)
	want << [u8(0xAA), 0xAA] // 22 bytes padded to 24
	assert b.data == want
	ch.send(bytes_from(62, 0))!
	c := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert c.data.len == 64 && c.data[0] == 0x00 && c.data[1] == 62 && c.data[2..] == bytes_from(62, 0)
	// past TX_DL - 2 it is a First Frame of TX_DL bytes
	ch.settings = settings_with(0xAA, 0, 0, 12, .fd)!
	ch.send(bytes_from(10, 0))!
	d := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert d.data[..2] == [u8(0x00), 10] && d.data.len == 12
	ch.fc_window_ms = 20 // no Flow Control comes; only its First Frame is looked at
	ch.send(bytes_from(11, 0)) or {}
	e := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert e.data.len == 12 && e.data[..2] == [u8(0x10), 11]
	ch.close()
	peer.close()
}

// A First Frame of TX_DL bytes, Consecutive Frames of TX_DL - 1 payload bytes, the last one padded
// up to the next CAN-FD length.
fn test_first_and_consecutive_frames_with_a_long_tx_dl() {
	mut peer := transport.open('inproc:isotp-fd-mf') or { panic(err) }
	mut ch := open_software('inproc:isotp-fd-mf', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.settings = settings_with(0xCC, 0, 0, 16, .fd)!
	pdu := bytes_from(41, 0) // 14 in the First Frame, 15, then 12 in a 13-byte frame padded to 16
	mut s := &FdSent{
		ch:  ch
		pdu: pdu
	}
	t := spawn s.run()
	ff := on_id(mut peer, 0x7E0, 2000) or { panic('no First Frame') }
	mut want := [u8(0x10), 41]
	want << pdu[..14]
	assert ff.data == want
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x30), 0, 0] })!
	cf1 := on_id(mut peer, 0x7E0, 2000) or { panic('no CF 1') }
	mut w1 := [u8(0x21)]
	w1 << pdu[14..29]
	assert cf1.data == w1
	cf2 := on_id(mut peer, 0x7E0, 2000) or { panic('no CF 2') }
	mut w2 := [u8(0x22)]
	w2 << pdu[29..]
	w2 << [u8(0xCC), 0xCC, 0xCC]
	assert cf2.data == w2
	t.wait()
	assert s.err == ''
	ch.close()
	peer.close()
}

struct FdSent {
mut:
	ch  &SoftChannel = unsafe { nil }
	pdu []u8
	err string
}

fn (mut s FdSent) run() {
	s.ch.send(s.pdu) or { s.err = err.msg() }
}

// Without padding a frame up to 8 bytes is as long as its content; a longer one still takes the next
// CAN-FD length, the only lengths such a frame has.
fn test_no_padding_still_rounds_a_long_frame_up() {
	mut peer := transport.open('inproc:isotp-fd-nopad') or { panic(err) }
	mut ch := open_software('inproc:isotp-fd-nopad', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.settings = settings_with(no_padding, 0, 0, 64, .fd)!
	ch.send(bytes_from(3, 1))!
	a := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert a.data == [u8(0x03), 1, 2, 3]
	ch.send(bytes_from(9, 1))!
	b := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert b.data.len == 12 && b.data[..11] == [u8(0x00), 9, 1, 2, 3, 4, 5, 6, 7, 8, 9]
	ch.close()
	peer.close()
}

// The format stated is on every frame the channel sends, the Flow Control included.
fn test_the_stated_format_is_on_every_frame() {
	mut peer := transport.open('inproc:isotp-fd-fmt') or { panic(err) }
	mut ch := open_software('inproc:isotp-fd-fmt', 0x7E0, 0x7E8, false) or { panic(err) }
	ch.settings = settings_with(0, 0, 0, 8, .fd)!
	ch.send([u8(1)])!
	a := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert a.fd && !a.brs
	ch.settings = settings_with(0, 0, 0, 8, .fd_brs)!
	ch.send([u8(1)])!
	b := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert b.fd && b.brs
	ch.settings = settings_with(0, 0, 0, 8, .classic)!
	ch.send([u8(1)])!
	c := on_id(mut peer, 0x7E0, 1000) or { panic('no frame') }
	assert !c.fd && !c.brs
	// the Flow Control it answers a First Frame with as a receiver
	ch.settings = settings_with(0, 0, 0, 8, .fd)!
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 10, 1, 2, 3, 4, 5, 6] })!
	ch.recv(30) or {}
	fc := on_id(mut peer, 0x7E0, 1000) or { panic('no Flow Control') }
	assert fc.data[0] == 0x30 && fc.fd
	ch.close()
	peer.close()
}

// Received with no setting: a Single Frame behind the escape, and a First Frame of 64 bytes with
// Consecutive Frames as long, the last one shorter.
fn test_fd_frames_are_received_with_no_setting() {
	mut peer := transport.open('inproc:isotp-fd-rx') or { panic(err) }
	mut ch := open_software('inproc:isotp-fd-rx', 0x7E0, 0x7E8, false) or { panic(err) }
	mut sf := [u8(0x00), 20]
	sf << bytes_from(20, 3)
	peer.send(transport.CanFrame{ id: 0x7E8, data: sf, fd: true })! // 22 bytes, padded to 24 on the bus
	assert ch.recv(1000)! == bytes_from(20, 3)
	pdu := bytes_from(200, 0) // 62, 63, 63, then 12 in a 13-byte frame
	mut ff := [u8(0x10), 200]
	ff << pdu[..62]
	peer.send(transport.CanFrame{ id: 0x7E8, data: ff, fd: true })!
	for i, r in [[62, 125], [125, 188], [188, 200]] {
		mut cf := [u8(0x21 + i)]
		cf << pdu[r[0]..r[1]]
		peer.send(transport.CanFrame{ id: 0x7E8, data: cf, fd: true })!
	}
	assert ch.recv(1000)! == pdu
	fc := on_id(mut peer, 0x7E0, 1000) or { panic('no Flow Control') }
	assert fc.data[0] == 0x30
	ch.close()
	peer.close()
}

// A frame no CAN-FD sender produces is refused: a Single Frame past 8 bytes without the escape, a
// Consecutive Frame longer than its First Frame or short with more to come, a First Frame whose
// length fits a Single Frame of its size, and one whose 32-bit length is one the 12 bits give.
fn test_malformed_fd_frames_are_refused() {
	mut peer := transport.open('inproc:isotp-fd-bad') or { panic(err) }
	mut ch := open_software('inproc:isotp-fd-bad', 0x7E0, 0x7E8, false) or { panic(err) }
	mut sf := [u8(0x09)]
	sf << bytes_from(9, 0)
	refused(mut peer, mut ch, [sf], 'escape')
	refused(mut peer, mut ch, [[u8(0x08), 1, 2, 3, 4, 5, 6, 7]], 'exceeds 7')
	mut ff16 := [u8(0x10), 100]
	ff16 << bytes_from(14, 0)
	refused(mut peer, mut ch, [ff16, []u8{len: 64, init: u8(0x21)}], 'longer than its 16-byte First Frame')
	mut ff64 := [u8(0x10), 200]
	ff64 << bytes_from(62, 0)
	refused(mut peer, mut ch, [ff64, []u8{len: 16, init: u8(0x21)}], 'short Consecutive Frame')
	mut ffsf := [u8(0x10), 62]
	ffsf << bytes_from(62, 0)
	refused(mut peer, mut ch, [ffsf], 'must be a Single Frame')
	mut ff32 := [u8(0x10), 0, 0, 0, 0x0F, 0xFF]
	ff32 << bytes_from(58, 0)
	refused(mut peer, mut ch, [ff32], 'the 12-bit form states')
	ch.close()
	peer.close()
}

// refused sends `frames` and expects the next receive to fail saying `want`.
fn refused(mut peer transport.Bus, mut ch SoftChannel, frames [][]u8, want string) {
	for f in frames {
		peer.send(transport.CanFrame{ id: 0x7E8, data: f, fd: f.len > 8 }) or { panic(err) }
	}
	if got := ch.recv(200) {
		assert false, 'taken: ${got}'
	} else {
		assert err.msg().contains(want), err.msg()
	}
	ch.drain_quiet(20)
}

// One channel sends a maximum message in 64-byte frames and another, stating nothing, reads it.
fn test_a_long_tx_dl_round_trip() {
	mut rx := open_software('inproc:isotp-fd-rt', 0x7E8, 0x7E0, false) or { panic(err) }
	mut tx := open_software('inproc:isotp-fd-rt', 0x7E0, 0x7E8, false) or { panic(err) }
	tx.settings = settings_with(0x55, 0, 0, 64, .fd)!
	want := []u8{len: max_pdu, init: u8(index * 7)}
	mut r := &FdReceived{
		ch: rx
	}
	t := spawn r.run()
	tx.send(want)!
	t.wait()
	assert r.err == ''
	assert r.got == want
	rx.close()
	tx.close()
}

// A message past 4095 bytes in classic frames: a First Frame of 10 00 and the 32-bit length with
// two bytes of the message, then Consecutive Frames of 7.
fn test_a_message_past_4095_bytes_in_classic_frames() {
	mut tap := transport.open('inproc:isotp-ff32') or { panic(err) }
	mut rx := open_software('inproc:isotp-ff32', 0x7E8, 0x7E0, false) or { panic(err) }
	mut tx := open_software('inproc:isotp-ff32', 0x7E0, 0x7E8, false) or { panic(err) }
	want := []u8{len: 5000, init: u8(index * 3)}
	mut r := &FdReceived{
		ch: rx
	}
	t := spawn r.run()
	tx.send(want)!
	t.wait()
	assert r.err == ''
	assert r.got == want
	ff := on_id(mut tap, 0x7E0, 1000) or { panic('no First Frame') }
	assert ff.data == [u8(0x10), 0, 0, 0, 0x13, 0x88, want[0], want[1]]
	cf := on_id(mut tap, 0x7E0, 1000) or { panic('no Consecutive Frame') }
	assert cf.data[0] == 0x21 && cf.data[1..] == want[2..9]
	rx.close()
	tx.close()
	tap.close()
}

// The longest message in 64-byte frames, the First Frame carrying 58 bytes behind the escape.
fn test_a_maximum_message_in_fd_frames() {
	mut tap := transport.open('inproc:isotp-ff32-fd') or { panic(err) }
	mut rx := open_software('inproc:isotp-ff32-fd', 0x7E8, 0x7E0, false) or { panic(err) }
	mut tx := open_software('inproc:isotp-ff32-fd', 0x7E0, 0x7E8, false) or { panic(err) }
	tx.settings = settings_with(0, 0, 0, 64, .fd)!
	want := []u8{len: max_pdu, init: u8(index * 5)}
	mut r := &FdReceived{
		ch: rx
	}
	t := spawn r.run()
	tx.send(want)!
	t.wait()
	assert r.err == ''
	assert r.got == want
	ff := on_id(mut tap, 0x7E0, 1000) or { panic('no First Frame') }
	assert ff.data.len == 64 && ff.data[..6] == [u8(0x10), 0, 0, 0, 0xFF, 0xFF]
	assert ff.data[6..] == want[..58]
	rx.close()
	tx.close()
	tap.close()
}

// A First Frame declaring more than max_pdu is answered with Flow Control OVERFLOW, and the
// sender hears the refusal.
fn test_a_message_past_max_pdu_is_answered_with_overflow() {
	mut peer := transport.open('inproc:isotp-ff32-ovf') or { panic(err) }
	mut ch := open_software('inproc:isotp-ff32-ovf', 0x7E0, 0x7E8, false) or { panic(err) }
	peer.send(transport.CanFrame{ id: 0x7E8, data: [u8(0x10), 0, 0, 1, 0, 0, 1, 2] })!
	if got := ch.recv(200) {
		assert false, 'taken: ${got.len} bytes'
	} else {
		assert err.msg().contains('OVERFLOW'), err.msg()
	}
	fc := on_id(mut peer, 0x7E0, 1000) or { panic('no Flow Control') }
	assert fc.data[..3] == [u8(0x32), 0, 0]
	ch.close()
	peer.close()
	if _ := ch.send([]u8{len: max_pdu + 1}) {
		assert false, 'past max_pdu sent'
	} else {
		assert err is transport.NotWritten
	}
}
