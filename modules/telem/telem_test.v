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

// emb: encode_record(new_fb(id: 2, flags: 0, start_us: 0x112233, cpu_us: 0x5566)).
// entity_id = kind_fb<<14 | 2 = 0x8002 (LE 02 80); start_us is a u24 now (b3-5).
fn test_record_roundtrip() {
	b := [u8(0x02), 0x80, 0, 0x33, 0x22, 0x11, 0x66, 0x55]
	d := decode_record(b)
	assert d.kind() == kind_fb
	assert d.id() == 2
	assert d.start_us == 0x112233
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

// A truncated frame must not panic — missing fields read 0, the entity id still decodes.
fn test_short_payload_safe() {
	d := decode_record([u8(0x07), 0x80]) // only entity_id (kind_fb id 7); rest reads 0
	assert d.kind() == kind_fb
	assert d.id() == 7
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

fn test_manifest_rejects_bad_ids() {
	// out of range: the entity id is 14-bit, so > 16383 is rejected (256 is now a valid id)
	if _ := parse_manifest('16384,p,1,F,h,1000') {
		assert false, 'id 16384 should be rejected (14-bit max is 16383)'
	}
	// non-numeric (would silently become 0)
	if _ := parse_manifest('x,p,1,F,h,1000') {
		assert false, 'non-numeric id should be rejected'
	}
	// duplicate id
	if _ := parse_manifest('1,p,1,A,a,1000\n1,p,1,B,b,2000') {
		assert false, 'duplicate id should be rejected'
	}
	// the 14-bit boundary id (16383) is accepted, and a >255 id no longer truncates
	m := parse_manifest('16383,p,1,F,h,1000\n300,p,1,G,g,1000') or { panic(err) }
	assert m.handlers[0].id == 16383
	assert m.lookup(300) or { panic('id 300 missing') }.fb == 'G' // not aliased to low byte 44
}

// Record kinds: a dumped stream mixes FB runs, THREAD intervals, ISR intervals, and (multi-core)
// CONTROL block headers / epochs in the same 8-byte cell — kind()/is_block_header()/is_epoch()
// classify, then the kind-specific accessors decode. Byte order matches emb comm/trace/trace.v.
fn test_record_kinds() {
	// FB run: entity_id kind_fb<<14|7 = 0x8007 (LE 07 80); info=flags 0; start 10000; cpu 100
	run := decode_record([u8(0x07), 0x80, 0, 0x10, 0x27, 0, 0x64, 0])
	assert run.kind() == kind_fb && run.id() == 7
	assert run.flags() == 0 && run.start_us == 10000 && run.cpu_us == 100

	// THREAD interval: entity_id kind_thread<<14|3 = 0x4003 (LE 03 40); info=reason; start 1234
	th := decode_record([u8(0x03), 0x40, reason_preempt, 0xD2, 0x04, 0, 50, 0])
	assert th.kind() == kind_thread && th.id() == 3 && !th.is_idle()
	assert th.reason() == reason_preempt && th.start_us == 1234 && th.cpu_us == 50

	// idle: kind_thread, id 0 (0x4000, LE 00 40)
	assert decode_record([u8(0x00), 0x40, 0, 0, 0, 0, 0, 0]).is_idle()

	// ISR interval: entity_id kind_isr<<14|16 = 0x0010 (LE 10 00); start 500; cpu 20
	isr := decode_record([u8(0x10), 0x00, 0, 0xF4, 0x01, 0, 20, 0])
	assert isr.kind() == kind_isr && isr.id() == 16 && isr.start_us == 500

	// block header: CONTROL/ctl_block (0xC000, LE 00 C0); info=core; start|cpu<<24=count
	hd := decode_record([u8(0x00), 0xC0, 2, 32, 0, 0, 0, 0])
	assert hd.is_block_header() && !hd.is_epoch()
	assert hd.header_core() == 2 && hd.header_count() == 32

	// epoch: CONTROL/ctl_epoch (0xC001, LE 01 C0); base = info<<24 | start_us(u24)
	ep := decode_record([u8(0x01), 0xC0, 0x01, 0, 0, 0, 0, 0])
	assert ep.is_epoch() && !ep.is_block_header()
	assert ep.epoch_base() == u32(0x01) << 24
}

// The `# trace frames` section carries the five observability CAN ids (config-driven on the
// target). parse_manifest reads them; a manifest without the section leaves frames zero and
// or_defaults() fills the built-in id_* wire. This is exactly loom2v's emitted layout.
fn test_manifest_trace_frames() {
	m := parse_manifest('# generated by loom2v
# fb.handlers: id,partition,core,fb,handler,period_us,thread
0,app,0,FastWork,on_5ms,5000,app_main
# threads: thread,id,name,core
thread,1,app_main,0
# trace frames: frame,id,bus
cmd,0x7e2,can0
rsp,0x7e3,can0
stat,0x7e4,can0
record,0x7e5,can0
dump_fc,0x7e6,can0
') or { panic(err) }
	assert m.handlers.len == 1 // the 7-column handler row (with a thread col) still parses
	assert m.threads.len == 1
	f := m.frames
	assert f.cmd == 0x7E2 && f.rsp == 0x7E3 && f.stat == 0x7E4
	assert f.record == 0x7E5 && f.dump_fc == 0x7E6
	// a manifest with no frames section -> zero frames -> or_defaults() fills the built-ins.
	m2 := parse_manifest('0,app,0,F,h,5000') or { panic(err) }
	assert m2.frames.cmd == 0 // absent
	d := m2.frames.or_defaults()
	assert d.cmd == id_trace_cmd && d.record == id_record && d.dump_fc == id_dump_fc
}

// The `# shell frames` section carries the CAN shell's three ids (in/fc/out). A manifest
// without the section leaves them zero and or_defaults() fills loom2v's [shell] defaults.
fn test_manifest_shell_frames() {
	m := parse_manifest('0,app,0,F,h,5000
# shell frames: frame,id,bus
in,0x7f0,can0
fc,0x7f2,can0
out,0x7f1,can0
') or { panic(err) }
	assert m.shell.input == 0x7F0 && m.shell.fc == 0x7F2 && m.shell.out == 0x7F1
	m2 := parse_manifest('0,app,0,F,h,5000') or { panic(err) }
	assert m2.shell.input == 0 // absent
	d := m2.shell.or_defaults()
	assert d.input == 0x7F0 && d.fc == 0x7F2 && d.out == 0x7F1
}

// A manifest may carry thread rows (thread,id,name,core) to label the swimlane thread lanes,
// alongside the handler rows. thread_label resolves them; unknown ids synthesise "thread N".
fn test_manifest_threads() {
	m := parse_manifest('0,app0,0,light,on_5ms,5000\nthread,0,app0,0\nthread,1,isr0,0') or {
		panic(err)
	}
	assert m.handlers.len == 1
	assert m.threads.len == 2
	assert m.thread_label(0, 0) == 'app0'
	assert m.thread_label(0, 1) == 'isr0'
	assert m.thread_label(0, 9) == 'thread 9' // unknown -> synthetic
	// a duplicate thread id ON ONE CORE is rejected
	if _ := parse_manifest('0,p,0,F,h,1000\nthread,0,a,0\nthread,0,b,0') {
		assert false, 'duplicate thread id on one core should be rejected'
	}
	// the SAME id on TWO cores is two threads (per-core recorder id spaces): both resolve
	m2 := parse_manifest('0,p,0,F,h,1000\nthread,1,comm,0,10\nthread,1,m4_app,1,11') or {
		panic(err)
	}
	assert m2.thread_label(0, 1) == 'comm'
	assert m2.thread_label(1, 1) == 'm4_app'
	assert m2.by_tid[tkey(1, 1)].prio == 11
}
