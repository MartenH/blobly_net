module transport

fn one(rec []u8) BridgeRecord {
	mut d := BridgeDecoder{}
	recs := d.feed(rec) or { panic(err) }
	assert recs.len == 1
	return recs[0]
}

fn test_hello_round_trips() {
	r := one(bridge_encode_hello('tok', 'Ubuntu-24.04', ['vcan0', 'vcan1'], ''))
	assert r.kind == .hello
	assert r.version == bridge_version
	assert r.token == 'tok'
	assert r.name == 'Ubuntu-24.04'
	assert r.channels == ['vcan0', 'vcan1']
	assert r.error == ''
	// A bridge that could not start says why in place of channels.
	f := one(bridge_encode_hello('tok', 'Ubuntu-24.04', [], 'no vcan module'))
	assert f.channels.len == 0 && f.error == 'no vcan module'
}

fn test_control_records_round_trip() {
	o := one(bridge_encode_open(3, 42))
	assert o.channel == 3 && o.gen == 42
	assert one(bridge_encode_close(4)).kind == .close
	ok := one(bridge_encode_opened(1, 42, ''))
	assert ok.kind == .opened && ok.gen == 42 && ok.error == ''
	bad := one(bridge_encode_opened(1, 42, 'no such device'))
	assert bad.error == 'no such device'
	se := one(bridge_encode_senderr(2, 77, true, 'Network is down'))
	assert se.kind == .senderr && se.channel == 2 && se.seq == 77 && se.definite
	assert se.error == 'Network is down'
	assert !one(bridge_encode_senderr(2, 78, false, 'x')).definite
	no := one(bridge_encode_refused('wrong token'))
	assert no.kind == .refused && no.error == 'wrong token'
	// A string longer than a record needs is cut, never sent whole.
	long := one(bridge_encode_lost(5, 42, 'x'.repeat(100_000)))
	assert long.error.len == bridge_max_str
	// ...and at a character boundary: 1023 ASCII bytes then a two-byte é keeps 1023.
	cut := one(bridge_encode_lost(5, 42, 'x'.repeat(bridge_max_str - 1) + 'é'))
	assert cut.error == 'x'.repeat(bridge_max_str - 1)
	lost := one(bridge_encode_lost(5, 42, 'recv failed'))
	assert lost.kind == .lost && lost.gen == 42 && lost.error == 'recv failed'
	st := one(bridge_encode_status(1, 42, .error_passive, BusDiagnostics{
		dropped:       1
		bus_errors:    2
		decode_errors: 3
	}))
	assert st.health == .error_passive && st.gen == 42
	assert st.diag == BusDiagnostics{
		dropped:       1
		bus_errors:    2
		decode_errors: 3
	}
}

fn test_frame_round_trips_every_flag() {
	f := CanFrame{
		id:       0x18DAF110
		extended: true
		fd:       true
		brs:      true
		esi:      true
		data:     []u8{len: 64, init: u8(index)}
	}
	r := one(bridge_encode_frame(7, 42, f, 0xDEADBEEF, true, -5))
	assert r.kind == .frame && r.channel == 7 && r.gen == 42 && r.seq == 0xDEADBEEF && r.tx
	assert r.stamp_ns == -5
	assert r.frame.id == f.id && r.frame.extended && r.frame.fd && r.frame.brs && r.frame.esi
	assert !r.frame.rtr
	assert r.frame.data == f.data
	rtr := one(bridge_encode_frame(0, 1, CanFrame{ id: 0x7FF, rtr: true, data: []u8{len: 2} }, 0,
		false, 0))
	assert rtr.frame.rtr && !rtr.tx && rtr.frame.data.len == 2
}

fn test_decoder_follows_any_read_boundary() {
	mut stream := bridge_encode_frame(1, 1, CanFrame{ id: 0x123, data: [u8(1), 2, 3] }, 9, false,
		42)
	stream << bridge_encode_status(1, 1, .ok, BusDiagnostics{})
	stream << bridge_encode_opened(0, 1, '')
	mut d := BridgeDecoder{}
	mut got := []BridgeRecord{}
	// One byte at a time, then all three back to back in one read.
	for b in stream {
		got << d.feed([b])!
	}
	assert got.len == 3
	assert got[0].frame.data == [u8(1), 2, 3]
	assert got[1].kind == .status
	assert got[2].kind == .opened
	mut d2 := BridgeDecoder{}
	assert d2.feed(stream)!.len == 3
}

fn test_decoder_refuses_what_is_not_a_bridge_stream() {
	mut d := BridgeDecoder{}
	// A length past the bound: nothing is allocated for it.
	mut huge := []u8{}
	put_u32_le(mut huge, u32(bridge_max_record + 1))
	if _ := d.feed(huge) {
		assert false
	}
	// A length past 2^31 is refused too, never read as a negative one.
	for big in [u32(0x8000_0000), 0xFFFF_FFFF] {
		mut d2 := BridgeDecoder{}
		mut hdr := []u8{}
		put_u32_le(mut hdr, big)
		if _ := d2.feed(hdr) {
			assert false, '${big:x}'
		}
	}
	assert bridge_decode_body([]u8{}) or { BridgeRecord{} }.kind != .frame
	// A frame body cut short.
	full := bridge_encode_frame(0, 1, CanFrame{ id: 1, data: [u8(1), 2] }, 1, false, 0)
	if _ := bridge_decode_body(full[4..full.len - 1]) {
		assert false
	}
	// A payload length past 64.
	mut big := full[4..].clone()
	big[23] = 65 // the payload length, after kind, channel, gen, flags, seq, id and stamp
	if _ := bridge_decode_body(big) {
		assert false
	}
	// An id wider than its kind: SocketCAN's can_id, its flag bits and all.
	for id, ext in {
		u32(0x800): false
		0x8000_0123: true
		0x2000_0000: true
	} {
		mut wide := bridge_encode_frame(0, 1, CanFrame{ id: 0x1, extended: ext }, 0, false, 0)[4..].clone()
		// the id, after kind, channel, gen, flags and seq
		for k in 0 .. 4 {
			wide[11 + k] = u8(id >> (8 * k))
		}
		if _ := bridge_decode_body(wide) {
			assert false, '${id:x} was read'
		}
	}
	// A channel entry cut short.
	mut hello := bridge_encode_hello('t', 'b', ['can0'], '')[4..].clone()
	assert hello[11] == 1 && hello[12] == 7 // one entry, of 7 bytes
	hello[12] = 3 // shorter than the name it carries
	if _ := bridge_decode_body(hello) {
		assert false
	}
}

// The four rules the format grows by without a new version.
fn test_what_a_reader_does_not_know_is_skipped() {
	// a record kind
	assert bridge_decode_body([u8(99), 1, 2, 3])!.kind == .unknown
	mut stream := bridge_encode_close(1)
	stream << [u8(3), 0, 0, 0, 200, 1, 2]
	stream << bridge_encode_close(2)
	mut d := BridgeDecoder{}
	recs := d.feed(stream)!
	assert recs.map(it.kind) == [BridgeKind.close, .unknown, .close]
	assert recs[2].channel == 2
	// fields after the known ones, of a record and of a channel entry
	mut frame := bridge_encode_frame(1, 7, CanFrame{ id: 0x55, data: [u8(9)] }, 0, false, 5)[4..].clone()
	frame << [u8(0xee), 0xee]
	f := bridge_decode_body(frame)!
	assert f.frame.id == 0x55 && f.frame.data == [u8(9)] && f.stamp_ns == 5
	mut entry := []u8{}
	bridge_put_str(mut entry, 'lin0')
	entry << [u8(2), 0xee, 0xee, 0xee]
	mut hello := [u8(BridgeKind.hello), 3, 0, 3, 0, 1, 0, `t`, 1, 0, `b`, 1]
	bridge_put_u16(mut hello, u16(entry.len))
	hello << entry
	hello << [u8(0), 0, 0xee]
	h := bridge_decode_body(hello)!
	assert h.channels == ['lin0'] && h.buses == [u8(2)] && h.error == '' && h.name == 'b'
	// a flag bit and a health
	frame[7] |= 0x80 // the flags, after kind, channel and gen
	assert bridge_decode_body(frame)!.frame == f.frame
	mut st := bridge_encode_status(0, 1, .ok, BusDiagnostics{ dropped: 4 })[4..].clone()
	st[6] = 9 // the health byte, after kind, channel and gen
	s := bridge_decode_body(st)!
	assert s.health == .unknown && s.diag.dropped == 4
}

fn test_parse_bridge_iface() {
	s := parse_bridge_iface('bridge:Ubuntu-24.04/vcan0')!
	assert s.name == 'Ubuntu-24.04' && s.channel == 'vcan0'
	for bad in ['bridge:', 'bridge:x', 'bridge:/vcan0', 'bridge:x/', 'vcan0', 'bridge:x/vcan0@500000'] {
		if _ := parse_bridge_iface(bad) {
			assert false, bad
		}
	}
	assert health_source('bridge:x/vcan0') == .polled
	assert echoes_own_sends('bridge:x/vcan0')
}

// The format is what a bridge on another machine is written against (#587), so its bytes are
// pinned here, spelled out from the header's description rather than from the encoder.
fn test_records_are_the_documented_bytes() {
	assert bridge_version == 3
	tok := '0123456789abcdef'
	mut hello := [u8(42), 0, 0, 0, 1, 3, 0, 3, 0, 16, 0]
	hello << tok.bytes()
	hello << [u8(5), 0]
	hello << 'board'.bytes()
	hello << [u8(1), 7, 0, 4, 0]
	hello << 'can0'.bytes()
	hello << [u8(1), 0, 0]
	assert bridge_encode_hello(tok, 'board', ['can0'], '') == hello
	h := one(hello)
	assert h.name == 'board' && h.version == 3 && h.oldest == 3 && h.buses == [bridge_bus_can]
	assert bridge_encode_welcome(3) == [u8(3), 0, 0, 0, 10, 3, 0]
	assert one(bridge_encode_welcome(3)).version == 3

	frame := [u8(26), 0, 0, 0, 5, 1, 7, 0, 0, 0, 0x21, 9, 0, 0, 0, 0x23, 0x01, 0, 0, 0xe8, 0x03,
		0, 0, 0, 0, 0, 0, 2, 0xaa, 0xbb]
	got := bridge_encode_frame(1, 7, CanFrame{ id: 0x123, extended: true, data: [u8(0xaa), 0xbb] },
		9, true, 1000)
	assert got == frame
	r := one(frame)
	assert r.frame.id == 0x123 && r.frame.extended && r.tx && r.seq == 9 && r.stamp_ns == 1000

	assert bridge_encode_open(3, 0x01020304) == [u8(6), 0, 0, 0, 2, 3, 4, 3, 2, 1]
	assert bridge_encode_close(3) == [u8(2), 0, 0, 0, 4, 3]
	assert bridge_encode_opened(3, 1, 'x') == [u8(9), 0, 0, 0, 3, 3, 1, 0, 0, 0, 1, 0, `x`]
	assert bridge_encode_senderr(3, 2, true, '') == [u8(9), 0, 0, 0, 6, 3, 2, 0, 0, 0, 1, 0, 0]
	assert bridge_encode_lost(3, 1, '') == [u8(8), 0, 0, 0, 8, 3, 1, 0, 0, 0, 0, 0]
	assert bridge_encode_refused('no') == [u8(5), 0, 0, 0, 9, 2, 0, `n`, `o`]
	mut status := [u8(31), 0, 0, 0, 7, 3, 1, 0, 0, 0, 3]
	status << [u8(4), 0, 0, 0, 0, 0, 0, 0, 5, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0]
	assert bridge_encode_status(3, 1, .error_passive, BusDiagnostics{
		dropped:       4
		bus_errors:    5
		decode_errors: 6
	}) == status
}
