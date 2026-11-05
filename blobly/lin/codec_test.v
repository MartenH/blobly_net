module lin

// Every PID, from an independent implementation (Python, LIN 2.2A §2.3.1.3).
const pid_table = [u8(0x80), 0xC1, 0x42, 0x03, 0xC4, 0x85, 0x06, 0x47, 0x08, 0x49, 0xCA, 0x8B,
	0x4C, 0x0D, 0x8E, 0xCF, 0x50, 0x11, 0x92, 0xD3, 0x14, 0x55, 0xD6, 0x97, 0xD8, 0x99, 0x1A, 0x5B,
	0x9C, 0xDD, 0x5E, 0x1F, 0x20, 0x61, 0xE2, 0xA3, 0x64, 0x25, 0xA6, 0xE7, 0xA8, 0xE9, 0x6A, 0x2B,
	0xEC, 0xAD, 0x2E, 0x6F, 0xF0, 0xB1, 0x32, 0x73, 0xB4, 0xF5, 0x76, 0x37, 0x78, 0x39, 0xBA, 0xFB,
	0x3C, 0x7D, 0xFE, 0xBF]

fn test_pid_every_id() {
	for id in 0 .. 64 {
		p := pid(u8(id))
		assert p == pid_table[id], 'id ${id}'
		assert id_of(p)? == u8(id)
		// Each single parity bit flipped is refused.
		assert id_of(p ^ 0x40) == none
		assert id_of(p ^ 0x80) == none
	}
	assert pid(0) == 0x80
	assert pid(1) == 0xC1
	assert pid(2) == 0x42
	assert pid(0x3C) == 0x3C
	assert pid(0x3D) == 0x7D
}

fn test_checksum_vectors() {
	data := [u8(0x4A), 0x55, 0x93, 0xE5]
	// The specification's classic example.
	assert checksum(.classic, pid(0x10), data) == 0xE6
	// Enhanced, from an independent implementation (Python: inverted sum with carry, PID first).
	assert checksum(.enhanced, pid(0x10), data) == 0x96
	assert checksum(.enhanced, pid(0x21), [u8(1), 2, 3, 4]) == 0x94
	assert checksum(.classic, pid(0x21), [u8(1), 2, 3, 4]) == 0xF5
	assert checksum(.enhanced, pid(0x3B), []u8{len: 8, init: 0xFF}) == 0x04
	assert checksum(.classic, pid(0x3B), []u8{len: 8, init: 0xFF}) == 0x00
	assert checksum(.enhanced, pid(0x01), [u8(0)]) == 0x3E
	// MasterReq and SlaveResp are classic whatever is asked.
	assert effective_model(0x3C, .enhanced) == .classic
	assert effective_model(0x3D, .enhanced) == .classic
	assert effective_model(0x3B, .enhanced) == .enhanced
	// So are the reserved ids 0x3E and 0x3F.
	assert effective_model(0x3E, .enhanced) == .classic
	assert effective_model(0x3F, .enhanced) == .classic
	assert checksum(.enhanced, pid(0x3E), [u8(1), 2]) == 0xFC
	assert checksum(.enhanced, pid(0x3F), [u8(1), 2]) == 0xFC
	assert checksum(.enhanced, pid(0x3C), sleep_data()) == checksum(.classic, pid(0x3C),
		sleep_data())
	assert checksum(.classic, pid(0x3C), sleep_data()) == 0x00
}

fn test_frame_length() {
	assert frame_bits(8) == 124
	assert frame_bits(1) == 54
	assert frame_bits_max(8) == 174 // 173.6 rounded up
	assert frame_bits_max(1) == 76 // 75.6
	assert frame_ns(8, 19200) == 6_458_333 // 124 bits at 19200 baud
}

// wire builds a PARMRK stream: a break, the sync, the PID, then the bytes, 0xFF escaped.
fn wire(id u8, bytes []u8) []u8 {
	mut out := [u8(0xFF), 0x00, 0x00, 0x55, pid(id)]
	for b in bytes {
		if b == 0xFF {
			out << [u8(0xFF), 0xFF]
		} else {
			out << b
		}
	}
	return out
}

fn with_cs(model Model, id u8, data []u8) []u8 {
	mut out := data.clone()
	out << checksum(model, pid(id), data)
	return out
}

fn table() map[u8]Expect {
	return {
		u8(0x21): Expect{
			len:   4
			model: .enhanced
		}
		u8(0x22): Expect{
			len:   2
			model: .classic
		}
	}
}

fn test_decode_good_frame_by_length() {
	mut d := new_decoder(table(), 19200)
	fs := d.feed(wire(0x21, with_cs(.enhanced, 0x21, [u8(1), 2, 3, 4])), 100)
	assert fs.len == 1
	f := fs[0]
	assert f.id == 0x21 && f.pid == 0x61
	assert f.data == [u8(1), 2, 3, 4]
	assert f.checksum == 0x94
	assert f.model == .enhanced
	assert f.errs == Errs.zero()
	assert f.raw.len == 5
	assert f.t_ns == 100
	assert f.src == .remote
}

fn test_decode_split_across_chunks() {
	mut d := new_decoder(table(), 19200)
	w := wire(0x22, with_cs(.classic, 0x22, [u8(0xFF), 0x10]))
	mut all := []Frame{}
	for i, b in w {
		all << d.feed([b], i64(i))
	}
	assert all.len == 1
	assert all[0].data == [u8(0xFF), 0x10]
	assert all[0].errs == Errs.zero()
	assert all[0].t_ns == i64(w.len - 1)
}

fn test_decode_escaped_ff_data() {
	mut d := new_decoder(table(), 19200)
	data := [u8(0xFF), 0xFF, 0x00, 0xFF]
	fs := d.feed(wire(0x21, with_cs(.enhanced, 0x21, data)), 0)
	assert fs.len == 1
	assert fs[0].data == data
	assert fs[0].errs == Errs.zero()
}

fn test_decode_framing_error() {
	mut d := new_decoder(table(), 19200)
	mut w := wire(0x22, [])
	w << [u8(0xFF), 0x00, 0x12] // 0x12 read with a framing error
	w << 0x34
	w << checksum(.classic, pid(0x22), [u8(0x12), 0x34])
	fs := d.feed(w, 0)
	assert fs.len == 1
	assert fs[0].errs.has(.framing)
	assert !fs[0].errs.has(.checksum)
	assert fs[0].data == [u8(0x12), 0x34]
}

fn test_decode_sync_error() {
	mut d := new_decoder(table(), 19200)
	fs := d.feed([u8(0xFF), 0x00, 0x00, 0x54, pid(0x21), 1, 2], 0)
	assert fs.len == 1
	assert fs[0].errs == Errs.sync
	// What follows a bad sync is not read as a frame.
	assert d.stray == 3
	assert reading(fs[0]) == 'header !sync'
}

fn test_decode_parity_error() {
	mut d := new_decoder(table(), 19200)
	fs := d.feed([u8(0xFF), 0x00, 0x00, 0x55, 0x21, 1, 2], 0) // 0x21 is not a valid PID
	assert fs.len == 1
	assert fs[0].errs == Errs.parity
	assert fs[0].pid == 0x21
	assert reading(fs[0]) == 'pid 0x21 !parity'
}

fn test_decode_checksum_error() {
	mut d := new_decoder(table(), 19200)
	fs := d.feed(wire(0x21, [u8(1), 2, 3, 4, 0x95]), 0)
	assert fs.len == 1
	assert fs[0].errs == Errs.checksum
	assert fs[0].checksum == 0x95
}

fn test_decode_short_then_break() {
	mut d := new_decoder(table(), 19200)
	mut w := wire(0x21, [u8(1), 2])
	w << wire(0x22, with_cs(.classic, 0x22, [u8(5), 6]))
	fs := d.feed(w, 7)
	assert fs.len == 2
	assert fs[0].id == 0x21
	assert fs[0].errs == Errs.short
	assert fs[0].data == [u8(1), 2]
	assert fs[1].id == 0x22 && fs[1].errs == Errs.zero()
}

fn test_decode_short_at_idle() {
	mut d := new_decoder(table(), 19200)
	assert d.feed(wire(0x21, [u8(1)]), 5).len == 0
	fs := d.idle(9)
	assert fs.len == 1
	assert fs[0].errs == Errs.short
	assert fs[0].t_ns == 5
}

fn test_decode_header_only() {
	mut d := new_decoder(table(), 19200)
	assert d.feed(wire(0x21, []), 3).len == 0
	fs := d.idle(50)
	assert fs.len == 1
	assert fs[0].errs == Errs.no_response
	assert fs[0].raw.len == 0
	assert fs[0].model == .enhanced
	// A header followed by another header is no response too.
	mut w := wire(0x21, [])
	w << wire(0x22, with_cs(.classic, 0x22, [u8(5), 6]))
	gs := d.feed(w, 0)
	assert gs.len == 2
	assert gs[0].errs == Errs.no_response
}

fn test_decode_lone_break_is_wakeup() {
	mut d := new_decoder(table(), 19200)
	assert d.feed([u8(0xFF), 0x00, 0x00], 11).len == 0
	fs := d.idle(20)
	assert fs.len == 1
	assert fs[0].event == .wakeup
	assert fs[0].errs == Errs.zero()
	// A break then another break: the first was a wakeup.
	gs := d.feed([u8(0xFF), 0x00, 0x00, 0xFF, 0x00, 0x00, 0x55, pid(0x22), 5, 6,
		checksum(.classic, pid(0x22), [u8(5), 6])], 30)
	assert gs.len == 2
	assert gs[0].event == .wakeup
	assert gs[1].id == 0x22 && gs[1].errs == Errs.zero()
}

fn test_decode_monitor_without_table() {
	mut d := new_decoder(map[u8]Expect{}, 19200)
	// Enhanced frame, ended by the next break.
	mut w := wire(0x21, with_cs(.enhanced, 0x21, [u8(1), 2, 3, 4]))
	// Classic frame, ended at idle.
	w << wire(0x10, with_cs(.classic, 0x10, [u8(0x4A), 0x55, 0x93, 0xE5]))
	fs := d.feed(w, 0)
	assert fs.len == 1
	assert fs[0].data == [u8(1), 2, 3, 4]
	assert fs[0].model == .enhanced
	assert fs[0].errs == Errs.zero()
	gs := d.idle(1)
	assert gs.len == 1
	assert gs[0].model == .classic
	assert gs[0].checksum == 0xE6
	assert gs[0].errs == Errs.zero()
	// Neither model matches.
	d.feed(wire(0x21, [u8(1), 2, 3, 4, 0x00]), 0)
	hs := d.idle(2)
	assert hs[0].errs == Errs.checksum
	// Eight data bytes and a checksum end the frame by themselves.
	ks := d.feed(wire(0x30, with_cs(.enhanced, 0x30, []u8{len: 8, init: u8(index)})), 0)
	assert ks.len == 1
	assert ks[0].data.len == 8 && ks[0].errs == Errs.zero()
}

fn test_decode_sleep_command() {
	mut d := new_decoder(map[u8]Expect{}, 19200)
	fs := d.feed(wire(0x3C, with_cs(.classic, 0x3C, sleep_data())), 0)
	assert fs.len == 1
	assert fs[0].event == .sleep
	assert fs[0].model == .classic
}

fn test_decode_short_pulse_is_wakeup() {
	// At 19200 baud a bit is 52 us: a run of 3 bits (start + 2, 0xFC) is the first to reach 150 us.
	mut d := new_decoder(table(), 19200)
	assert d.feed([u8(0xFC)], 40).len == 0
	fs := d.idle(90)
	assert fs.len == 1
	assert fs[0].event == .wakeup && fs[0].t_ns == 40
	assert d.stray == 0
	// 0x00 confirmed by a break; the frame after it reads as ever.
	mut w := [u8(0x00)]
	w << wire(0x22, with_cs(.classic, 0x22, [u8(5), 6]))
	gs := d.feed(w, 50)
	assert gs.len == 2
	assert gs[0].event == .wakeup
	assert gs[1].id == 0x22 && gs[1].errs == Errs.zero()
	// Too short a run (start + 1 bit, 104 us), or not one run from the start bit: stray.
	d.feed([u8(0xFE)], 60)
	assert d.idle(70).len == 0
	d.feed([u8(0x0F)], 80)
	assert d.idle(90).len == 0
	assert d.stray == 2
	// The same 0xFE is a wakeup at 9600 baud (two bits, 208 us).
	mut slow := new_decoder(table(), 9600)
	slow.feed([u8(0xFE)], 1)
	assert slow.idle(2).len == 1
}

fn test_decode_pulse_among_noise_is_stray() {
	mut d := new_decoder(table(), 19200)
	// A candidate followed by another byte is noise, and so is every candidate after it.
	d.feed([u8(0x00), 0x00, 0x00], 0)
	assert d.idle(1).len == 0
	assert d.stray == 3
	// After a stray byte, a candidate before the next idle is noise too.
	d.feed([u8(0x12), 0x00], 2)
	assert d.idle(3).len == 0
	assert d.stray == 5
	// After a bad sync, the frame's leftover bytes do not make a wakeup.
	d.feed([u8(0xFF), 0x00, 0x00, 0x54, 0x07, 0x00], 4)
	fs := d.idle(5)
	assert fs.len == 0
}
