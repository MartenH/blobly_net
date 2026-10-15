module transport

fn one(rec []u8) BridgeRecord {
	mut d := BridgeDecoder{}
	recs := d.feed(rec) or { panic(err) }
	assert recs.len == 1
	return recs[0]
}

fn test_hello_round_trips() {
	r := one(bridge_encode_hello('tok', 'Ubuntu-24.04', ['vcan0', 'vcan1']))
	assert r.kind == .hello
	assert r.version == bridge_version
	assert r.token == 'tok'
	assert r.name == 'Ubuntu-24.04'
	assert r.channels == ['vcan0', 'vcan1']
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
	if _ := bridge_decode_body([u8(99)]) {
		assert false
	}
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
	// A health rung this decoder does not know.
	mut st := bridge_encode_status(0, 1, .ok, BusDiagnostics{})[4..].clone()
	st[6] = 9 // the health byte, after kind, channel and gen
	if _ := bridge_decode_body(st) {
		assert false
	}
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
