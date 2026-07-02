module telem

// The byte vectors below are exactly what blobly_emb/comm/{telem,trace}.encode_* emit
// (cross-checked against emb's telem_test.v / trace_test.v). Decoding them here proves
// blobly_net reads the ECU's frames byte-for-byte — the wire is the cross-repo contract.

// emb: encode_handlerstat(5, flag_overran, 1234, 5678, 42)
fn test_handlerstat_roundtrip() {
	b := [u8(5), flag_overran, 0xD2, 0x04, 0x2E, 0x16, 0x2A, 0x00] // 1234, 5678, 42 LE
	d := decode_handlerstat(b)
	assert d.handler_id == 5
	assert d.flags == flag_overran
	assert d.last_us == 1234
	assert d.max_us == 5678
	assert d.count_delta == 42
}

// emb: encode_handlerstat(0, 0, 70000, 100, 99999) clamps last + count to 0xFFFF and
// sets the saturated flag; max (100) is in range.
fn test_handlerstat_saturated() {
	b := [u8(0), flag_saturated, 0xFF, 0xFF, 0x64, 0x00, 0xFF, 0xFF]
	d := decode_handlerstat(b)
	assert d.last_us == 0xFFFF
	assert d.max_us == 100
	assert d.count_delta == 0xFFFF
	assert d.flags & flag_saturated != 0
}

// emb: encode_record(Record{start_us: 0x11223344, cpu_us: 0x5566, handler_id: 2, flags: 0})
fn test_record_roundtrip() {
	b := [u8(2), 0, 0x44, 0x33, 0x22, 0x11, 0x66, 0x55]
	d := decode_record(b)
	assert d.handler_id == 2
	assert d.start_us == 0x11223344
	assert d.cpu_us == 0x5566
}

// emb: encode_loaddetail(...) -> percent bytes + overrun count
fn test_loaddetail() {
	d := decode_loaddetail([u8(50), 40, 30, 2, 0, 0, 0, 0])
	assert d.load_100ms == 50
	assert d.load_1s == 40
	assert d.load_10s == 30
	assert d.overruns == 2
}

// A truncated frame must not panic — missing fields read 0, the id still decodes.
fn test_short_payload_safe() {
	d := decode_record([u8(7), flag_first_run]) // only 2 bytes
	assert d.handler_id == 7
	assert d.flags == flag_first_run
	assert d.start_us == 0
	assert d.cpu_us == 0
}

const sample_manifest = '# a manifest
id,partition,core,fb,handler,period_us
0,one,1,SpeedFilter,on_10ms,10000
2,ctrl,2,SpeedMonitor,on_20ms,20000
'

fn test_manifest_parse_and_lookup() {
	m := parse_manifest(sample_manifest) or { panic(err) }
	assert m.handlers.len == 2
	h0 := m.lookup(0) or { panic('id 0 missing') }
	assert h0.fb == 'SpeedFilter'
	assert h0.core == 1
	assert h0.period_us == 10000
	assert h0.name() == 'SpeedFilter.on_10ms'
	h2 := m.lookup(2) or { panic('id 2 missing') }
	assert h2.handler == 'on_20ms'
	// an unmapped id -> none, and label() synthesises a name
	assert m.lookup(1) == none
	assert m.label(1) == 'handler 1'
	assert m.label(0) == 'SpeedFilter.on_10ms'
}
