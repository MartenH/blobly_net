module uds

// Captured from blobly_emb's own fault memory (examples/overspeed on vcan0, 2026-09-30): five DTCs,
// no operation cycle started yet, so every one untested this cycle and since the last clear.
const emb_19_01 = [u8(0x59), 0x01, 0x7F, 0x01, 0x00, 0x05]
const emb_19_02 = [u8(0x59), 0x02, 0x7F, 0x02, 0x19, 0x00, 0x50, 0x05, 0x06, 0x00, 0x50, 0xC1, 0x21,
	0x00, 0x50, 0xC4, 0x18, 0x00, 0x50, 0xC4, 0x18, 0x01, 0x50]
const emb_19_02_confirmed = [u8(0x59), 0x02, 0x7F]

fn test_blobly_emb_answers_decode() {
	n := decode_dtc_count(emb_19_01) or { panic(err) }
	assert n.availability == 0x7F && n.format == 0x01 && n.count == 5
	r := decode_dtc_list(emb_19_02) or { panic(err) }
	assert r.availability == 0x7F
	assert r.records.map(it.name()) == ['P0219-00', 'P0506-00', 'U0121-00', 'U0418-00', 'U0418-01']
	assert r.records.all(it.status == 0x50)
	assert r.records[2].has(dtc_not_completed_this_cycle | dtc_not_completed_since_clear)
	assert !r.records[2].has(dtc_test_failed)
	none_ := decode_dtc_list(emb_19_02_confirmed) or { panic(err) }
	assert none_.records.len == 0
	u := r.find(0xC12100) or { panic('U0121-00 missing') }
	assert u.str() == 'U0121-00 0x50 [testNotCompletedSinceLastClear, testNotCompletedThisOperationCycle]'
}

// the display name and its parse are inverses; each system letter from the code's top two bits
fn test_dtc_names() {
	for code, name in {
		u32(0x021900): 'P0219-00'
		u32(0x523000): 'C1230-00'
		u32(0x9ABC12): 'B1ABC-12'
		u32(0xC41801): 'U0418-01'
	} {
		assert dtc_name(code) == name
		assert dtc_code(name) or { panic(name) } == code
	}
	assert dtc_code('U0121') or { panic('short') } == 0xC12100
	for bad in ['X0121-00', 'U4121-00', 'U01G1-00', 'U0121_00', 'U012'] {
		assert dtc_code(bad) == none, bad
	}
}

fn test_a_malformed_list_is_refused() {
	decode_dtc_list([u8(0x59), 0x02, 0x7F, 0x01, 0x02]) or {
		assert err.msg().contains('whole number')
		return
	}
	assert false
}

fn test_the_in_process_server_answers_every_supported_sub_function() {
	mut s := default_server()
	n := decode_dtc_count(s.handle([u8(0x19), 0x01, 0xFF])) or { panic(err) }
	assert n.count == 2
	all := decode_dtc_list(s.handle([u8(0x19), 0x0A])) or { panic(err) }
	assert all.records.len == 2
	confirmed := decode_dtc_list(s.handle([u8(0x19), 0x02, dtc_confirmed])) or { panic(err) }
	assert confirmed.records.len == 2 // both default DTCs carry confirmedDTC (0x08)
	failed := decode_dtc_list(s.handle([u8(0x19), 0x02, dtc_test_failed])) or { panic(err) }
	assert failed.records.map(it.name()) == ['P1234-56'] // 0x123456: only it has testFailed
}
