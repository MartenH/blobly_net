module telem

// the layout under watch: one cyclic tx frame with u8/u32/i16/u64 fields
const ew_manifest = '# eth frames
ethframe,BenchTelem,0x8001,15,tx,cyclic,300000,-
ethlayout,BenchTelem,BenchLoad,load,0,1,u8
ethlayout,BenchTelem,BenchTicks,ticks,1,4,u32
ethlayout,BenchTelem,BenchTemp,temp,5,2,i16
ethlayout,BenchTelem,BenchStamp,stamp,7,8,u64
# fb.handlers
0,app,0,Bench,on_100ms,100000
'

fn ew_watch(m Manifest, field string) EthWatch {
	for fld in m.eth_fields('BenchTelem') {
		if fld.field == field {
			return EthWatch{0x8001, 'eth0', fld}
		}
	}
	panic('field ${field} not in the test manifest')
}

fn test_sample_decodes_to_f64() {
	m := parse_manifest(ew_manifest) or { panic(err) }
	// load=0x2A, ticks=0x00010000, temp=-2 (0xFFFE le), stamp=u64 max
	payload := [u8(0x2A), 0, 0, 1, 0, 0xFE, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
		0xFF]
	assert ew_watch(m, 'load').sample(payload) or { panic(err) } == 42.0
	assert ew_watch(m, 'ticks').sample(payload) or { panic(err) } == 65536.0
	// signed field sign-extends: the sample is negative
	assert ew_watch(m, 'temp').sample(payload) or { panic(err) } == -2.0
	// u64 above i64 max must plot POSITIVE (decode carries the bits as i64;
	// sample converts via u64). f64 rounds u64 max to 2^64 — precision above
	// 2^53 is lost, sign must not be.
	stamp := ew_watch(m, 'stamp').sample(payload) or { panic(err) }
	assert stamp == f64(u64(0xFFFF_FFFF_FFFF_FFFF))
	assert stamp > 0
}

fn test_sample_short_payload_is_none() {
	m := parse_manifest(ew_manifest) or { panic(err) }
	// a torn payload must read as absent (no sample), never as garbage
	if _ := ew_watch(m, 'stamp').sample([u8(1), 2, 3]) {
		assert false, 'short payload produced a sample'
	}
}

fn test_reconcile_keeps_valid_drops_stale() {
	m := parse_manifest(ew_manifest) or { panic(err) }
	// the rebuilt manifest: same frame id, `load` moved to offset 2, `ticks` gone
	m2 := parse_manifest('# eth frames
ethframe,BenchTelem,0x8001,15,tx,cyclic,300000,-
ethlayout,BenchTelem,BenchLoad,load,2,1,u8
# fb.handlers
0,app,0,Bench,on_100ms,100000
') or { panic(err) }
	ws := [
		ew_watch(m, 'load'), // still exists — kept, snapshot refreshed
		ew_watch(m, 'ticks'), // field gone — dropped
		EthWatch{0x9999, 'eth0', ew_watch(m, 'load').fld}, // frame id gone — dropped
	]
	kept := m2.reconcile_eth_watches(ws, 'eth1')
	assert kept.len == 1
	assert kept[0].fld.field == 'load'
	assert kept[0].fld.offset == 2 // fresh snapshot, not the stale offset-0 one
	assert kept[0].ch == 'eth1' // retargeted to the current someip channel
}

fn test_reconcile_no_someip_channel_drops_all() {
	m := parse_manifest(ew_manifest) or { panic(err) }
	assert m.reconcile_eth_watches([ew_watch(m, 'load')], '').len == 0
}
