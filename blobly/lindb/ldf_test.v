module lindb

import os

// dbc/lin_demo.ldf is the hand-written LIN 2.2A fixture: one feature per frame. Its dump below
// is ldfparser's reading of it (sut/ldf_oracle.py, ldfparser 0.26.0), line for line, so CI pins
// the oracle's answer without Python.
fn fixture() Ldf {
	path := os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'lin_demo.ldf')
	return load_ldf(path) or { panic(err) }
}

fn fixture_text() string {
	return os.read_file(os.join_path(os.dir(@FILE), '..', '..', 'dbc', 'lin_demo.ldf')) or {
		panic(err)
	}
}

const fixture_dump = 'header protocol=2.2 language=2.2 speed_bps=19200 channel=DB
master CEM time_base_ms=5 jitter_ms=0.1
slaves LSM,RSM
node LSM protocol=2.2 configured_nad=0x20 initial_nad=0x01 product=0x4A4F,0x4841,1 response_error=LSMerror fault_state=IntTest p2_min_ms=150 st_min_ms=50 n_as_ms=1000 n_cr_ms=1000 frames=Node_Status_Event,CEM_Frm1,LSM_Frm1,LSM_Frm2,LSM_Frm3
node RSM protocol=2.1 configured_nad=0x21 initial_nad=0x21 product=0x4E4E,0x4553,- response_error=RSMerror fault_state= p2_min_ms=100 st_min_ms=20 n_as_ms=500 n_cr_ms=750 frames=Node_Status_Event,CEM_Frm1,RSM_Frm1,RSM_Frm2,RSM_Frm3
signal CabinTemp width=8 init=120 publisher=CEM subscribers=LSM,RSM encoding=TempEncoding
signal IntTest width=2 init=0 publisher=LSM subscribers=CEM encoding=FaultStateEncoding
signal InternalLightsRequest width=2 init=0 publisher=CEM subscribers=LSM,RSM encoding=Dig2Bit
signal LSM_Ident width=32 init={76,83,77,49} publisher=LSM subscribers=CEM encoding=IdentEncoding
signal LSMerror width=1 init=0 publisher=LSM subscribers=CEM encoding=ErrorEncoding
signal LeftIntLightsSwitch width=8 init=0 publisher=LSM subscribers=CEM encoding=LightEncoding
signal MasterReqB0 width=8 init=0 publisher=- subscribers= encoding=-
signal MasterReqB1 width=8 init=0 publisher=- subscribers= encoding=-
signal MasterReqB2 width=8 init=0 publisher=- subscribers= encoding=-
signal MasterReqB3 width=8 init=0 publisher=- subscribers= encoding=-
signal MasterReqB4 width=8 init=0 publisher=- subscribers= encoding=-
signal MasterReqB5 width=8 init=0 publisher=- subscribers= encoding=-
signal MasterReqB6 width=8 init=0 publisher=- subscribers= encoding=-
signal MasterReqB7 width=8 init=0 publisher=- subscribers= encoding=-
signal NightMode width=1 init=1 publisher=CEM subscribers=LSM encoding=ModeEncoding
signal RSM_PartNo width=24 init={1,2,3} publisher=RSM subscribers=CEM encoding=PartNoEncoding
signal RSM_Serial width=64 init={16,32,48,64,80,96,112,128} publisher=RSM subscribers=CEM encoding=-
signal RSMerror width=1 init=0 publisher=RSM subscribers=CEM encoding=ErrorEncoding
signal RightIntLightsSwitch width=8 init=0 publisher=RSM subscribers=CEM encoding=LightEncoding
signal SlaveRespB0 width=8 init=0 publisher=- subscribers= encoding=-
signal SlaveRespB1 width=8 init=0 publisher=- subscribers= encoding=-
signal SlaveRespB2 width=8 init=0 publisher=- subscribers= encoding=-
signal SlaveRespB3 width=8 init=0 publisher=- subscribers= encoding=-
signal SlaveRespB4 width=8 init=0 publisher=- subscribers= encoding=-
signal SlaveRespB5 width=8 init=0 publisher=- subscribers= encoding=-
signal SlaveRespB6 width=8 init=0 publisher=- subscribers= encoding=-
signal SlaveRespB7 width=8 init=0 publisher=- subscribers= encoding=-
signal VehicleSpeed width=12 init=250 publisher=CEM subscribers=RSM encoding=SpeedEncoding
encoding Dig2Bit logical value=0 text=off
encoding Dig2Bit logical value=1 text=on
encoding Dig2Bit logical value=2 text=error
encoding Dig2Bit logical value=3 text=void
encoding ErrorEncoding logical value=0 text=OK
encoding ErrorEncoding logical value=1 text=error
encoding FaultStateEncoding logical value=0 text=No test result
encoding FaultStateEncoding logical value=1 text=failed
encoding FaultStateEncoding logical value=2 text=passed
encoding FaultStateEncoding logical value=3 text=not used
encoding IdentEncoding ascii
encoding LightEncoding logical value=0 text=Off
encoding LightEncoding physical min=1 max=254 scale=1 offset=100 unit=lux
encoding LightEncoding logical value=255 text=error
encoding ModeEncoding logical value=0 text=day
encoding ModeEncoding logical value=1 text=night
encoding PartNoEncoding bcd
encoding SpeedEncoding physical min=0 max=4000 scale=0.0625 offset=0 unit=km/h
encoding SpeedEncoding logical value=4095 text=invalid
encoding TempEncoding physical min=0 max=199 scale=0.5 offset=-40 unit=degC
encoding TempEncoding physical min=200 max=250 scale=1 offset=60 unit=degC
encoding TempEncoding logical value=255 text=sensor fault
frame CEM_Frm1 id=0x01 publisher=CEM len=1 checksum=enhanced
frame-signal CEM_Frm1 InternalLightsRequest offset=0 width=2
frame-signal CEM_Frm1 NightMode offset=2 width=1
template CEM_Frm1 FC
frame CEM_Frm2 id=0x02 publisher=CEM len=3 checksum=enhanced
frame-signal CEM_Frm2 CabinTemp offset=0 width=8
frame-signal CEM_Frm2 VehicleSpeed offset=10 width=12
template CEM_Frm2 78EBC3
frame LSM_Frm1 id=0x11 publisher=LSM len=2 checksum=enhanced
frame-signal LSM_Frm1 LeftIntLightsSwitch offset=8 width=8
template LSM_Frm1 1100
frame LSM_Frm2 id=0x12 publisher=LSM len=1 checksum=enhanced
frame-signal LSM_Frm2 LSMerror offset=0 width=1
frame-signal LSM_Frm2 IntTest offset=1 width=2
template LSM_Frm2 F8
frame LSM_Frm3 id=0x13 publisher=LSM len=4 checksum=enhanced
frame-signal LSM_Frm3 LSM_Ident offset=0 width=32
template LSM_Frm3 4C534D31
frame RSM_Frm1 id=0x21 publisher=RSM len=2 checksum=enhanced
frame-signal RSM_Frm1 RightIntLightsSwitch offset=8 width=8
template RSM_Frm1 6100
frame RSM_Frm2 id=0x22 publisher=RSM len=4 checksum=enhanced
frame-signal RSM_Frm2 RSMerror offset=0 width=1
frame-signal RSM_Frm2 RSM_PartNo offset=8 width=24
template RSM_Frm2 FE010203
frame RSM_Frm3 id=0x23 publisher=RSM len=8 checksum=enhanced
frame-signal RSM_Frm3 RSM_Serial offset=0 width=64
template RSM_Frm3 1020304050607080
diag-frame MasterReq id=0x3C publisher=CEM len=8 checksum=classic
frame-signal MasterReq MasterReqB0 offset=0 width=8
frame-signal MasterReq MasterReqB1 offset=8 width=8
frame-signal MasterReq MasterReqB2 offset=16 width=8
frame-signal MasterReq MasterReqB3 offset=24 width=8
frame-signal MasterReq MasterReqB4 offset=32 width=8
frame-signal MasterReq MasterReqB5 offset=40 width=8
frame-signal MasterReq MasterReqB6 offset=48 width=8
frame-signal MasterReq MasterReqB7 offset=56 width=8
template MasterReq 0000000000000000
diag-frame SlaveResp id=0x3D publisher=- len=8 checksum=classic
frame-signal SlaveResp SlaveRespB0 offset=0 width=8
frame-signal SlaveResp SlaveRespB1 offset=8 width=8
frame-signal SlaveResp SlaveRespB2 offset=16 width=8
frame-signal SlaveResp SlaveRespB3 offset=24 width=8
frame-signal SlaveResp SlaveRespB4 offset=32 width=8
frame-signal SlaveResp SlaveRespB5 offset=40 width=8
frame-signal SlaveResp SlaveRespB6 offset=48 width=8
frame-signal SlaveResp SlaveRespB7 offset=56 width=8
template SlaveResp 0000000000000000
event Node_Status_Event id=0x3A table=Collision_resolver frames=RSM_Frm1,LSM_Frm1 checksum=enhanced
sporadic CEM_Sporadic frames=CEM_Frm2,CEM_Frm1
schedule NormalTable 0 frame CEM_Frm1 delay_ms=10
schedule NormalTable 1 frame CEM_Frm2 delay_ms=10
schedule NormalTable 2 frame LSM_Frm2 delay_ms=10
schedule NormalTable 3 frame RSM_Frm2 delay_ms=15
schedule NormalTable 4 event_triggered Node_Status_Event delay_ms=10
schedule FastTable 0 frame CEM_Frm2 delay_ms=5
schedule FastTable 1 frame RSM_Frm1 delay_ms=5
schedule FastTable 2 frame LSM_Frm1 delay_ms=5
schedule FastTable 3 frame LSM_Frm3 delay_ms=10
schedule FastTable 4 frame RSM_Frm3 delay_ms=15
schedule FastTable 5 sporadic CEM_Sporadic delay_ms=10
schedule FastTable 6 diagnostic MasterReq delay_ms=20
schedule FastTable 7 diagnostic SlaveResp delay_ms=20
schedule Collision_resolver 0 frame RSM_Frm1 delay_ms=10
schedule Collision_resolver 1 frame LSM_Frm1 delay_ms=10
schedule ConfigTable 0 command AssignNAD delay_ms=15
schedule ConfigTable 1 command AssignFrameIdRange delay_ms=15
schedule ConfigTable 2 command SaveConfiguration delay_ms=15
'

const fixture_notes = [
	'Event_triggered_frames: 1 frame parsed; v1 does not run event-triggered frames',
	'Sporadic_frames: 1 frame parsed; v1 does not run sporadic frames',
	'Schedule_tables: 3 configuration commands kept for their slot time; v1 does not send them',
]

fn test_fixture_reads_as_the_oracle_does() {
	l := fixture()
	assert l.dump() == fixture_dump
	assert l.notes == fixture_notes
}

fn test_fixture_accessors() {
	l := fixture()
	assert l.protocol_version == '2.2'
	assert l.language_version == '2.2'
	assert (l.speed_bps or { 0 }) == 19200
	assert l.channel == 'DB'
	assert l.master.name == 'CEM'
	assert (l.master.time_base_ms or { 0 }) == 5.0
	assert (l.master.jitter_ms or { 0 }) == 0.1
	assert l.slaves == ['LSM', 'RSM']

	f := l.frame('CEM_Frm2') or { panic('no CEM_Frm2') }
	assert f.id == 0x02 && f.length == 3 && f.publisher == 'CEM' && f.kind == .unconditional
	assert f.signals == [Mapped{'CabinTemp', 0}, Mapped{'VehicleSpeed', 10}]
	assert (l.frame_by_id(0x23) or { panic('no 0x23') }).name == 'RSM_Frm3'
	assert (l.frame_by_id(0x3D) or { panic('no 0x3D') }).kind == .diagnostic
	assert !l.frames.any(it.id == 0x30)
	assert !l.frames.any(it.name == 'Nope')

	// the diagnostic frames are classic whatever anyone declares; RSM declares 2.1, LSM 2.2
	for id, want in {
		u8(0x01): Checksum.enhanced
		0x11:     .enhanced
		0x21:     .enhanced
		0x3A:     .enhanced
		0x3C:     .classic
		0x3D:     .classic
	} {
		assert l.checksum_model_for(id)! == want, '0x${id:02X}'
	}
	if _ := l.checksum_model_for(0x30) {
		assert false, 'an id no frame has has no checksum model'
	} else {
		assert err.msg() == 'no frame has id 0x30'
	}

	slots := l.schedule('NormalTable') or { panic('no NormalTable') }
	assert slots == [
		Slot{.frame, 'CEM_Frm1', '', 10},
		Slot{.frame, 'CEM_Frm2', '', 10},
		Slot{.frame, 'LSM_Frm2', '', 10},
		Slot{.frame, 'RSM_Frm2', '', 15},
		Slot{.event_triggered, 'Node_Status_Event', '', 10},
	]
	fast := l.schedule('FastTable') or { panic('no FastTable') }
	assert fast.map(it.frame) == ['CEM_Frm2', 'RSM_Frm1', 'LSM_Frm1', 'LSM_Frm3', 'RSM_Frm3',
		'CEM_Sporadic', 'MasterReq', 'SlaveResp']
	assert fast.map(it.delay_ms) == [5.0, 5, 5, 10, 15, 10, 20, 20]
	assert fast[5].kind == .sporadic && fast[6].kind == .diagnostic
	cfg := l.schedule('ConfigTable') or { panic('no ConfigTable') }
	assert cfg[0] == Slot{.command, '', 'AssignNAD', 15}
	assert !l.schedules.any(it.name == 'Nope')

	lsm := l.node('LSM') or { panic('no LSM') }
	assert lsm.protocol == '2.2'
	assert (lsm.configured_nad or { 0 }) == 0x20
	assert (lsm.initial() or { 0 }) == 0x01
	p := lsm.product or { panic('no product') }
	assert p.supplier == 0x4A4F && p.function == 0x4841 && (p.variant or { 0 }) == 1
	assert lsm.response_error == 'LSMerror' && lsm.fault_state_signals == ['IntTest']
	assert lsm.p2_min() == 150 && lsm.st_min() == 50
	assert lsm.n_as_timeout() == 1000 && lsm.n_cr_timeout() == 1000
	assert lsm.configurable_frames.map(it.name) == ['Node_Status_Event', 'CEM_Frm1', 'LSM_Frm1',
		'LSM_Frm2', 'LSM_Frm3']
	rsm := l.node('RSM') or { panic('no RSM') }
	assert rsm.protocol == '2.1'
	if _ := rsm.initial_nad {
		assert false, 'RSM states no initial NAD'
	}
	assert (rsm.initial() or { 0 }) == 0x21 // the configured NAD where none is stated
	// RSM states no variant, and none is read in its place
	if v := (rsm.product or { panic('no product') }).variant {
		assert false, 'RSM states no variant, read ${v}'
	}
	assert rsm.p2_min() == 100 && rsm.st_min() == 20
	assert rsm.n_as_timeout() == 500 && rsm.n_cr_timeout() == 750

	ev := l.event_frame('Node_Status_Event') or { panic('no event frame') }
	assert ev.id == 0x3A && ev.table == 'Collision_resolver' && ev.frames == [
		'RSM_Frm1',
		'LSM_Frm1',
	]
	assert l.sporadic_frames[0].frames == ['CEM_Frm2', 'CEM_Frm1']

	ident := l.signal('LSM_Ident') or { panic('no LSM_Ident') }
	assert ident.is_array && ident.width == 32 && ident.init_bytes == 'LSM1'.bytes()
	assert ident.encoding == 'IdentEncoding'
	temp := l.encoding('TempEncoding') or { panic('no TempEncoding') }
	assert temp.rules == [
		EncRule{.physical, 0, 199, 0.5, -40, 'degC'},
		EncRule{.physical, 200, 250, 1, 60, 'degC'},
		EncRule{.logical, 255, 255, 0, 0, 'sensor fault'},
	]
	assert l.template(f) == [u8(0x78), 0xEB, 0xC3]
}

// The sections may come in any order: the fixture's blocks reversed read the same.
fn test_sections_in_any_order_read_the_same() {
	blocks := fixture_text().split('\n\n')
	assert blocks.len > 10
	shuffled := parse_ldf(blocks.reverse().join('\n\n')) or { panic(err) }
	assert shuffled.dump() == fixture_dump
	assert shuffled.notes == fixture_notes
}

fn test_comments_go_anywhere() {
	plain := 'LIN_description_file;
LIN_protocol_version = "2.2";
LIN_language_version = "2.2";
LIN_speed = 19.2 kbps;
Channel_name = "a//b /* c */";
Nodes { Master: M, 5 ms, 1 ms; Slaves: S; }
Signals { A: 8, 3, M, S; }
Frames { F: 1, M, 1 { A, 0; } }
Schedule_tables { T { F delay 10 ms; } }'
	commented := '/* a header
   over lines */ LIN_description_file // trailing
;LIN_protocol_version/**/= "2.2"; // "not a string
LIN_language_version = /* inside a statement */ "2.2";
LIN_speed = 19.2 /* between a value and its unit */ kbps;
Channel_name = "a//b /* c */";
Nodes { // a block comment opens here /*
  Master: M, 5 ms, 1 ms; Slaves: S; }
Signals { A: 8, 3, M, S; /* ; } */ }
Frames { F: 1, M, 1 { A, 0; } }
Schedule_tables { T { F delay 10 ms; } } // at the end, no newline'
	a := parse_ldf(plain) or { panic(err) }
	b := parse_ldf(commented) or { panic(err) }
	assert a.dump() == b.dump()
	assert a.channel == 'a//b /* c */'
	slave := "Node_attributes S: no attributes; its frames take the file's checksum model and it has no NAD"
	assert a.notes == [slave] && b.notes == [slave]
	if _ := parse_ldf('LIN_description_file; /* never closed') {
		assert false
	} else {
		assert err.msg() == '1:23: comment opened here is never closed'
	}
}

// LIN 1.3: no Node_attributes, classic everywhere, a frame's length taken from its id.
// This is the oracle's reading of the text too (sut/ldf_oracle.py).
const lin13 = 'LIN_description_file;
LIN_protocol_version = "1.3";
LIN_language_version = "1.3";
LIN_speed = 9.6 kbps;
Nodes { Master: ECU, 10 ms, 0.5 ms; Slaves: Door; }
Signals {
  Lock: 2, 0, ECU, Door;
  Window: 8, 0x7F, Door, ECU;
  Status: 4, 3, Door, ECU;
  Wide: 16, 0x1234, ECU, Door;
}
Frames {
  EcuCmd: 0x10, ECU { Lock, 0; }
  DoorStat: 0x21, Door { Window, 0; Status, 8; }
  EcuLong: 0x30, ECU { Wide, 4; }
}
Schedule_tables { Main { EcuCmd delay 20 ms; DoorStat delay 20 ms; EcuLong delay 40 ms; } }
'

const lin13_dump = 'header protocol=1.3 language=1.3 speed_bps=9600 channel=-
master ECU time_base_ms=10 jitter_ms=0.5
slaves Door
signal Lock width=2 init=0 publisher=ECU subscribers=Door encoding=-
signal Status width=4 init=3 publisher=Door subscribers=ECU encoding=-
signal Wide width=16 init=4660 publisher=ECU subscribers=Door encoding=-
signal Window width=8 init=127 publisher=Door subscribers=ECU encoding=-
frame EcuCmd id=0x10 publisher=ECU len=2 checksum=classic
frame-signal EcuCmd Lock offset=0 width=2
template EcuCmd FCFF
frame DoorStat id=0x21 publisher=Door len=4 checksum=classic
frame-signal DoorStat Window offset=0 width=8
frame-signal DoorStat Status offset=8 width=4
template DoorStat 7FF3FFFF
frame EcuLong id=0x30 publisher=ECU len=8 checksum=classic
frame-signal EcuLong Wide offset=4 width=16
template EcuLong 4F23F1FFFFFFFFFF
schedule Main 0 frame EcuCmd delay_ms=20
schedule Main 1 frame DoorStat delay_ms=20
schedule Main 2 frame EcuLong delay_ms=40
'

fn test_lin13() {
	l := parse_ldf(lin13) or { panic(err) }
	assert l.dump() == lin13_dump
	assert l.notes == []
	// LIN 2.1 and later need the length; the same frame there is refused
	l21 := parse_ldf(lin13.replace('"1.3"', '"2.1"')) or { panic(err) }
	assert 'Frames EcuCmd: length is missing, which LIN 2.1 and later require; not read' in l21.notes
	assert !l21.frames.any(it.name == 'EcuCmd')
}

// LIN 2.0: configurable frames with message ids, an event-triggered frame with no collision
// table (its frames carry their own PIDs in byte 0), and a LIN 1.3 slave in a LIN 2.0 cluster,
// whose frames are classic — and so is the master's frame it subscribes to. The oracle agrees
// with everything here but the event-triggered frame, which ldfparser 0.26.0 cannot read.
const lin20 = 'LIN_description_file;
LIN_protocol_version = "2.0";
LIN_language_version = "2.0";
LIN_speed = 19.2 kbps;
Nodes { Master: M, 5 ms, 0.1 ms; Slaves: S1, S2; }
Signals {
  A: 8, 1, M, S1;
  B: 4, 2, S1, M;
  C: 4, 5, S2, M;
}
Frames {
  MF: 0x05, M, 1 { A, 0; }
  S1F: 0x06, S1, 2 { B, 8; }
  S2F: 0x07, S2, 2 { C, 8; }
}
Event_triggered_frames { Ev: 0x08, S1F, S2F; }
Node_attributes {
  S1 { LIN_protocol = "1.3"; configured_NAD = 0x10; product_id = 0x1, 0x2, 3; P2_min = 10 ms; configurable_frames { MF = 0x1001; S1F = 0x1002; Ev = 0x1003; } }
  S2 { LIN_protocol = 2.0; configured_NAD = 0x11; product_id = 0x1, 0x3; configurable_frames { MF = 0x2001; S2F = 0x2002; } }
}
Schedule_tables { T { MF delay 10 ms; Ev delay 10 ms; S1F delay 10 ms; S2F delay 10 ms; } }
'

const lin20_dump = 'header protocol=2.0 language=2.0 speed_bps=19200 channel=-
master M time_base_ms=5 jitter_ms=0.1
slaves S1,S2
node S1 protocol=1.3 configured_nad=0x10 initial_nad=0x10 product=0x0001,0x0002,3 response_error=- fault_state= p2_min_ms=10 st_min_ms=0 n_as_ms=1000 n_cr_ms=1000 frames=MF=0x1001,S1F=0x1002,Ev=0x1003
node S2 protocol=2.0 configured_nad=0x11 initial_nad=0x11 product=0x0001,0x0003,- response_error=- fault_state= p2_min_ms=50 st_min_ms=0 n_as_ms=1000 n_cr_ms=1000 frames=MF=0x2001,S2F=0x2002
signal A width=8 init=1 publisher=M subscribers=S1 encoding=-
signal B width=4 init=2 publisher=S1 subscribers=M encoding=-
signal C width=4 init=5 publisher=S2 subscribers=M encoding=-
frame MF id=0x05 publisher=M len=1 checksum=classic
frame-signal MF A offset=0 width=8
template MF 01
frame S1F id=0x06 publisher=S1 len=2 checksum=classic
frame-signal S1F B offset=8 width=4
template S1F 06F2
frame S2F id=0x07 publisher=S2 len=2 checksum=enhanced
frame-signal S2F C offset=8 width=4
template S2F 47F5
event Ev id=0x08 table=- frames=S1F,S2F checksum=-
schedule T 0 frame MF delay_ms=10
schedule T 1 event_triggered Ev delay_ms=10
schedule T 2 frame S1F delay_ms=10
schedule T 3 frame S2F delay_ms=10
'

fn test_lin20() {
	l := parse_ldf(lin20) or { panic(err) }
	assert l.dump() == lin20_dump
	assert l.notes == ['Event_triggered_frames: 1 frame parsed; v1 does not run event-triggered frames']
	// S1 (LIN 1.3) and S2 (LIN 2.0) answer Ev with different checksums: the id has no one model
	if _ := l.checksum_model_for(0x08) {
		assert false
	} else {
		assert err.msg() == 'event-triggered frame Ev carries frames of different checksum models; the answering frame decides'
	}
	cf := (l.node('S1') or { panic('no S1') }).configurable_frames[0]
	assert cf.name == 'MF' && (cf.message_id or { 0 }) == 0x1001
}

fn test_iso17987_and_j2602_are_read_with_a_note() {
	iso := parse_ldf(lin13.replace('"1.3"', '"ISO17987:2015"').replace('{ Lock, 0; }', ', 2 { Lock, 0; }').replace('{ Window, 0;', ', 4 { Window, 0;').replace('{ Wide, 4; }', ', 8 { Wide, 4; }')) or {
		panic(err)
	}
	assert iso.notes == [
		'header: LIN_protocol_version "ISO17987:2015" is ISO 17987; read as LIN 2.2',
		'header: LIN_language_version "ISO17987:2015" is ISO 17987; read as LIN 2.2',
		"Node_attributes Door: no attributes; its frames take the file's checksum model and it has no NAD",
	]
	assert iso.checksum_model_for(0x10)! == .enhanced
	j := parse_ldf(lin13.replace('"1.3"', '"J2602_1_1.0"')) or { panic(err) }
	assert 'header: LIN_protocol_version "J2602_1_1.0" is SAE J2602; read as LIN 2.0' in j.notes
	assert j.checksum_model_for(0x10)! == .enhanced // and, as LIN 2.0, a length may be left to the id
}

// --- the leaf table ---------------------------------------------------------------------------

// leaf_template is a small valid LDF in which every field the leaf table governs is a
// placeholder `@section/field@`, and leaf_fields the good value and element name of each.
const leaf_template = 'LIN_description_file;
LIN_protocol_version = "@header/LIN_protocol_version@";
LIN_language_version = "@header/LIN_language_version@";
LIN_speed = @header/LIN_speed@ kbps;
Nodes { Master: M, @Nodes/time_base@ ms, @Nodes/jitter@ ms; Slaves: S; }
Signals {
  Sc: @Signals/width@, @Signals/init@, M, S;
  Ar: @Signals/array width@, {@Signals/init byte@, 0}, S, M;
  Hs: 8, 0, S, M;
}
Diagnostic_signals { MasterReqB0: @Diagnostic_signals/width@, @Diagnostic_signals/init@; }
Frames {
  F: @Frames/id@, M, @Frames/length@ { Sc, @Frames/offset@; }
  G: 0x02, S, 2 { Ar, 0; }
  H: 0x03, S, 2 { Hs, 8; }
}
Diagnostic_frames { MasterReq: @Diagnostic_frames/id@ { MasterReqB0, @Diagnostic_frames/offset@; } }
Event_triggered_frames { Ev: T, @Event_triggered_frames/id@, H; }
Node_attributes {
  S {
    LIN_protocol = "@Node_attributes/LIN_protocol@";
    configured_NAD = @Node_attributes/configured_NAD@;
    initial_NAD = @Node_attributes/initial_NAD@;
    product_id = @Node_attributes/supplier_id@, @Node_attributes/function_id@, @Node_attributes/variant@;
    P2_min = @Node_attributes/P2_min@ ms;
    ST_min = @Node_attributes/ST_min@ ms;
    N_As_timeout = @Node_attributes/N_As_timeout@ ms;
    N_Cr_timeout = @Node_attributes/N_Cr_timeout@ ms;
    configurable_frames { G = @Node_attributes/message_id@; }
  }
}
Schedule_tables { T { F delay @Schedule_tables/delay@ ms; } }
Signal_encoding_types {
  E {
    logical_value, @Signal_encoding_types/logical_value@, "x";
    physical_value, @Signal_encoding_types/min@, @Signal_encoding_types/max@, @Signal_encoding_types/scale@, @Signal_encoding_types/offset@, "u";
  }
}
Signal_representation { E: Sc; }
'

struct LeafField {
	good    string
	element string
}

const leaf_fields = {
	'header/LIN_protocol_version':         LeafField{'2.2', ''}
	'header/LIN_language_version':         LeafField{'2.2', ''}
	'header/LIN_speed':                    LeafField{'19.2', ''}
	'Nodes/time_base':                     LeafField{'5', 'Master'}
	'Nodes/jitter':                        LeafField{'0.1', 'Master'}
	'Signals/width':                       LeafField{'8', 'Sc'}
	'Signals/init':                        LeafField{'0', 'Sc'}
	'Signals/array width':                 LeafField{'16', 'Ar'}
	'Signals/init byte':                   LeafField{'0xFF', 'Ar'}
	'Diagnostic_signals/width':            LeafField{'8', 'MasterReqB0'}
	'Diagnostic_signals/init':             LeafField{'0', 'MasterReqB0'}
	'Frames/id':                           LeafField{'0x01', 'F'}
	'Frames/length':                       LeafField{'2', 'F'}
	'Frames/offset':                       LeafField{'0', 'F'}
	'Diagnostic_frames/id':                LeafField{'0x3C', 'MasterReq'}
	'Diagnostic_frames/offset':            LeafField{'0', 'MasterReq'}
	'Event_triggered_frames/id':           LeafField{'0x3A', 'Ev'}
	'Node_attributes/LIN_protocol':        LeafField{'2.1', 'S'}
	'Node_attributes/configured_NAD':      LeafField{'0x21', 'S'}
	'Node_attributes/initial_NAD':         LeafField{'0x01', 'S'}
	'Node_attributes/supplier_id':         LeafField{'0x4E4E', 'S'}
	'Node_attributes/function_id':         LeafField{'0x4553', 'S'}
	'Node_attributes/variant':             LeafField{'1', 'S'}
	'Node_attributes/P2_min':              LeafField{'50', 'S'}
	'Node_attributes/ST_min':              LeafField{'0', 'S'}
	'Node_attributes/N_As_timeout':        LeafField{'1000', 'S'}
	'Node_attributes/N_Cr_timeout':        LeafField{'1000', 'S'}
	'Node_attributes/message_id':          LeafField{'0x1001', 'S'}
	'Schedule_tables/delay':               LeafField{'10', 'T'}
	'Signal_encoding_types/logical_value': LeafField{'0', 'E'}
	'Signal_encoding_types/min':           LeafField{'1', 'E'}
	'Signal_encoding_types/max':           LeafField{'254', 'E'}
	'Signal_encoding_types/scale':         LeafField{'0.5', 'E'}
	'Signal_encoding_types/offset':        LeafField{'-40', 'E'}
}

fn leaf_doc(bad_key string, bad string) string {
	mut doc := leaf_template
	for key, f in leaf_fields {
		mut v := if key == bad_key { bad } else { f.good }
		// an empty value is written as an empty string; inside quotes it already is one
		if v == '' && !doc.contains('"@${key}@"') {
			v = '""'
		}
		doc = doc.replace('@${key}@', v)
	}
	assert !doc.contains('@'), doc
	return doc
}

// Every row of the table, fed every kind of bad value it exists to refuse, files exactly ONE
// note naming the element, the field and the text — and the all-good document files none. A new
// row without a template entry fails here, so the class stays covered as the table grows.
fn test_every_leaf_rule_refuses_bad_values_once() {
	good := parse_ldf(leaf_doc('', '')) or { panic(err) }
	assert good.notes == ['Event_triggered_frames: 1 frame parsed; v1 does not run event-triggered frames']
	assert good.frames.len == 4 && good.nodes.len == 1 && good.schedules.len == 1

	for l in ldf_leaves {
		key := '${l.section}/${l.field}'
		f := leaf_fields[key] or { panic('the leaf table has a row with no template field: ${key}') }
		mut bads := []string{}
		match l.kind {
			.integer {
				bads << ['x', '', '1.5', '-1', '0x', '0xZZ', '0x10000000000000000', '1e309']
				if l.lo > 0 {
					bads << '${l.lo - 1}'
				}
				if l.hi < max_u64 {
					bads << '${l.hi + 1}'
				}
				if l.step > 1 {
					bads << '${l.lo + l.step / 2}'
				}
			}
			.number {
				bads << ['x', '', '1e', '1.2.3', '0x', '1e309']
				if l.flo > -1e300 {
					bads << if l.open_lo { fmt_num(l.flo) } else { fmt_num(l.flo - 1) }
				}
				if l.fhi < 1e300 {
					bads << fmt_num(l.fhi + 1)
				}
			}
			.version {
				bads << ['x', '', '3.0', '2', '2.x', 'ISO17987:', 'J2602_1.0']
			}
		}
		at := if f.element == '' { l.section } else { '${l.section} ${f.element}' }
		for bad in bads {
			got := parse_ldf(leaf_doc(key, bad)) or { panic('${key} = "${bad}": ${err}') }
			want := '${at}: ${l.field} "${bad}" '
			hits := got.notes.filter(it.starts_with(want))
			assert hits.len == 1, '${key} = "${bad}": ${got.notes}'
			assert hits[0].ends_with('; not read'), hits[0]
		}
	}
}

// The bounds themselves, stated here independently of the table: the value just outside each
// LIN limit is refused and the one just inside is read.
fn test_the_lin_bounds() {
	for key, edge in {
		'header/LIN_speed':               ['20', '20.5']
		'Frames/id':                      ['59', '60']
		'Frames/length':                  ['8', '9']
		'Frames/offset':                  ['8', '64']
		'Diagnostic_frames/id':           ['0x3C', '0x3E']
		'Event_triggered_frames/id':      ['0x3B', '0x3C']
		'Signals/width':                  ['64', '65']
		'Signals/array width':            ['64', '72']
		'Node_attributes/configured_NAD': ['0x7D', '0x7E']
		'Node_attributes/supplier_id':    ['0x7FFE', '0x7FFF']
		'Node_attributes/function_id':    ['0xFFFE', '0xFFFF']
		'Schedule_tables/delay':          ['0.1', '0']
	} {
		f := leaf_fields[key] or { panic(key) }
		section := key.all_before('/')
		field := key.all_after('/')
		at := if f.element == '' { section } else { '${section} ${f.element}' }
		mut inside := leaf_doc(key, edge[0])
		if key == 'Signals/array width' {
			inside = inside.replace('{0xFF, 0}', '{0xFF, 0, 0, 0, 0, 0, 0, 0}').replace('G: 0x02, S, 2',
				'G: 0x02, S, 8')
		}
		if key == 'Frames/offset' {
			inside = inside.replace('M, 2 { Sc', 'M, 8 { Sc') // offset 8 of an 8-byte frame fits
		}
		ok := parse_ldf(inside) or { panic(err) }
		assert !ok.notes.any(it.starts_with('${at}: ${field} ')), '${key} = ${edge[0]}: ${ok.notes}'
		bad := parse_ldf(leaf_doc(key, edge[1])) or { panic(err) }
		assert bad.notes.any(it.starts_with('${at}: ${field} "${edge[1]}" ')), '${key} = ${edge[1]}: ${bad.notes}'
	}
}

// --- relations beside the table --------------------------------------------------------------

fn test_relations_the_table_cannot_state() {
	base := leaf_doc('', '')
	cases := {
		'  Sc: 8, 0, M, S;':             ['  Sc: 4, 16, M, S;',
			'Signals Sc: init "16" does not fit 4 bits; not read']
		'{0xFF, 0}':                     ['{1, 2, 3}',
			'Signals Ar: init has 3 bytes, a 16-bit array 2; not read']
		'{ Sc, 0; }':                    ['{ Sc, 12; }',
			'Frames F: signal Sc at offset 12, 8 bits wide, does not fit 2 bytes; not mapped']
		'G: 0x02, S, 2 { Ar, 0; }':      ['G: 0x02, S, 2 { Ar, 0; Hs, 4; }',
			'Frames G: signal Hs at offset 4 overlaps signal Ar; not mapped']
		'MasterReq: 0x3C':               ['MasterReq: 0x3D',
			'Diagnostic_frames MasterReq: id "0x3D" is not 0x3C; not read']
		'G: 0x02,':                      ['G: 0x01,', 'Frames G: id "0x01" is frame F\'s too; not read']
		'physical_value, 1, 254,':       ['physical_value, 254, 1,',
			'Signal_encoding_types E: physical_value min 254 is above max 1; not read']
		'Diagnostic_frames { MasterReq': ['Diagnostic_frames { Diag',
			'Diagnostic_frames Diag: a diagnostic frame is MasterReq or SlaveResp; not read']
		'Ev: T, 0x3A, H;':               ['Ev: T, 0x01, H;',
			'Event_triggered_frames Ev: id "0x01" is frame F\'s too; not read']
		'LIN_speed = 19.2 kbps;':        ['LIN_speed = 19.2 bps;',
			'header: LIN_speed "19.2 bps" is not a rate in kbps; not read']
		'P2_min = 50 ms;':               ['P2_min = 50 s;',
			'Node_attributes S: P2_min "50 s" is not a time in ms; not read']
	}
	for from, c in cases {
		assert base.contains(from), from
		l := parse_ldf(base.replace(from, c[0])) or { panic(err) }
		assert c[1] in l.notes, '${c[0]}: ${l.notes}'
	}
}

fn test_a_missing_reference_is_said_by_section_and_name() {
	base := leaf_doc('', '')
	l := parse_ldf(base.replace('{ Sc, 0; }', '{ Sc, 0; Ghost, 8; }').replace('F delay 10 ms;',
		'F delay 10 ms; Phantom delay 5 ms;').replace('E: Sc;', 'E: Sc, Nobody;').replace('Ev: T,',
		'Ev: Resolver,').replace('configurable_frames { G', 'response_error = Missing; configurable_frames { G')) or {
		panic(err)
	}
	for want in [
		'Frames F: maps signal Ghost, which Signals does not define; not mapped',
		'Schedule_tables T: names frame Phantom, which Frames does not define; not read',
		'Signal_representation E: names signal Nobody, which Signals does not define; not applied',
		'Event_triggered_frames Ev: names collision-resolving table Resolver, which Schedule_tables does not define',
		'Node_attributes S: response_error names signal Missing, which Signals does not define',
	] {
		assert want in l.notes, '${want}\n${l.notes}'
	}
	assert !l.schedules.any(it.name == 'T') // a table with a slot it cannot send is not a table to run
	// a reference to an element that was refused says so, not that it is undefined
	r := parse_ldf(base.replace('Sc: 8, 0,', 'Sc: 99, 0,').replace('Schedule_tables { T { F delay 10 ms; } }',
		'Schedule_tables { T { F delay 0 ms; } }')) or { panic(err) }
	assert 'Signals Sc: width "99" is out of range 1..64; not read' in r.notes
	assert 'Frames F: maps signal Sc, which was not read; not mapped' in r.notes
	assert 'Event_triggered_frames Ev: names collision-resolving table T, which was not read' in r.notes
	// a node attribute for a node that is no slave
	n := parse_ldf(base.replace('  S {', '  X {')) or { panic(err) }
	assert 'Node_attributes X: is not a slave of Nodes' in n.notes
}

fn test_skipped_sections_are_counted_never_dropped() {
	extra := '
LDF_file_revision = "1.0";
LIN_sig_byte_order_little_endian;
composite { configuration C1 { S { S, M } } configuration C2 { S { S } } }
Signal_groups { Grp: 16 { Sc, 0; Ar, 8; } }
Diagnostic_addresses { S: 0x21; }
'
	base := leaf_doc('', '').replace('Master: M, 5 ms, 0.1 ms;', 'Master: M, 5 ms, 0.1 ms, 48 bits, 40 %;').replace('initial_NAD = 0x01;',
		'initial_NAD = 0x01; response_tolerance = 38 %;')
	l := parse_ldf(base + extra) or { panic(err) }
	for want in [
		'LDF_file_revision: header statement not read',
		'Node_composition: 2 configurations parsed and not modelled',
		'Signal_groups: 1 group parsed and not modelled',
		'Diagnostic_addresses: section of 1 entry not read',
		'Nodes Master: 2 further values (J2602 header length, response tolerance) not read',
		'Node_attributes S: response_tolerance not read',
		'Event_triggered_frames: 1 frame parsed; v1 does not run event-triggered frames',
	] {
		assert want in l.notes, '${want}\n${l.notes}'
	}
	be := parse_ldf(base + 'LIN_sig_byte_order_big_endian;') or { panic(err) }
	assert 'header: LIN_sig_byte_order_big_endian is not supported; no signal is mapped into a frame' in be.notes
	assert (be.frame('F') or { panic('no F') }).signals == []
}

fn test_a_file_that_cannot_be_parsed_is_an_error_at_line_and_column() {
	for src, want in {
		'LIN_description_file':                                   "1:21: expected ';', found end of file"
		'LIN_description_file;\nNodes { Master: M, 5 ms, 1 ms }': "2:31: expected ';', found '}'"
		'Signals { A: 8, 0, M, S; ':                              '1:26: expected a signal name, found end of file'
		'Frames {\n  F: 1, M, 1 { A 0; }\n}':                     "2:18: expected ',', found '0'"
		'LIN_speed = 19.2 kbps; #':                               '1:24: unexpected character #'
		'Channel_name = "open':                                   '1:16: string is never closed'
		'Schedule_tables { T { F 10 ms; } }':                     "1:25: expected 'delay', found '10'"
		'42;':                                                    "1:1: expected a section or a header statement, found '42'"
	} {
		if _ := parse_ldf(src) {
			assert false, src
		} else {
			assert err.msg() == want, '${src}: ${err.msg()}'
		}
	}
	if _ := load_ldf('/nonexistent/x.ldf') {
		assert false
	}
}

// --- checksums by subscriber, tied frames, repeats ---------------------------------------------

// A master's frame is sent in the model of the slaves subscribing to it: classic to a LIN 1.x
// slave, none at all to 1.x and 2.x slaves together; a slave's frame must be checked in its
// publisher's model by every subscribing slave. The oracle agrees on this text.
const mixed = 'LIN_description_file;
LIN_protocol_version = "2.1";
LIN_language_version = "2.1";
LIN_speed = 19.2 kbps;
Nodes { Master: M, 5 ms, 0.1 ms; Slaves: S13, S21; }
Signals {
  A: 8, 0, M, S13;
  B: 8, 0, M, S21;
  C: 8, 0, M, S13, S21;
  D: 8, 0, S21, M, S13;
  E: 8, 0, M;
}
Frames {
  ToOld: 0x10, M, 1 { A, 0; }
  ToNew: 0x11, M, 1 { B, 0; }
  ToBoth: 0x12, M, 1 { C, 0; }
  NewToOld: 0x13, S21, 1 { D, 0; }
  ToNone: 0x14, M, 1 { E, 0; }
}
Node_attributes {
  S13 { LIN_protocol = "1.3"; configured_NAD = 0x01; product_id = 0x1, 0x1; }
  S21 { LIN_protocol = "2.1"; configured_NAD = 0x02; product_id = 0x1, 0x2, 0; }
}
'

fn test_a_master_frame_takes_its_subscribers_checksum() {
	l := parse_ldf(mixed) or { panic(err) }
	assert l.checksum_model_for(0x10)! == .classic
	assert l.checksum_model_for(0x11)! == .enhanced
	assert l.checksum_model_for(0x14)! == .enhanced
	for id, want in {
		u8(0x12): 'frame ToBoth is subscribed by LIN 1.x and 2.x slaves; no single checksum model serves both'
		0x13:     'frame NewToOld is sent enhanced by S21 and checked classic by subscriber S13; no single checksum model serves both'
	} {
		if c := l.checksum_model_for(id) {
			assert false, '0x${id:02X} read as ${c}'
		} else {
			assert err.msg() == want
		}
	}
}

fn test_protected_id() {
	for id, want in {
		u8(0x00): u8(0x80)
		0x01:     0xC1
		0x02:     0x42
		0x03:     0x03
		0x11:     0x11
		0x21:     0x61
		0x3C:     0x3C
		0x3D:     0x7D
	} {
		assert protected_id(id) == want, '0x${id:02X}'
	}
}

// A frame an event-triggered frame carries keeps byte 0 for its own protected id; a signal there
// is not mapped, and the tied frames' lengths and publishers are held to the rule.
fn test_tied_frames() {
	src := 'LIN_description_file;
LIN_protocol_version = "2.2";
LIN_language_version = "2.2";
LIN_speed = 19.2 kbps;
Nodes { Master: M, 5 ms, 0.1 ms; Slaves: S1, S2; }
Signals { A: 8, 0, S1, M; B: 8, 0, S1, M; C: 8, 0, S1, M; }
Frames {
  F1: 0x10, S1, 2 { A, 8; C, 0; }
  F2: 0x11, S1, 4 { B, 8; }
}
Event_triggered_frames { ET: Coll, 0x3A, F1, F2; }
Node_attributes {
  S1 { LIN_protocol = "2.2"; configured_NAD = 0x01; product_id = 0x1, 0x1; }
  S2 { LIN_protocol = "2.2"; configured_NAD = 0x02; product_id = 0x1, 0x2; }
}
Schedule_tables { Coll { F1 delay 10 ms; F2 delay 10 ms; } }
'
	l := parse_ldf(src) or { panic(err) }
	for want in [
		"Frames F1: signal C at offset 0 is in byte 0, which carries the frame's protected id for an event-triggered frame; not mapped",
		'Event_triggered_frames ET: carries F1 and F2, both published by S1',
		'Event_triggered_frames ET: carries frames of unequal length (F1 2, F2 4 bytes)',
	] {
		assert want in l.notes, '${want}\n${l.notes}'
	}
	f2 := l.frame('F2') or { panic('no F2') }
	assert l.template(f2) == [u8(0x11), 0x00, 0xFF, 0xFF]
	assert l.encode(f2, {
		'B': Value(u64(6))
	})! == [u8(0x11), 0x06, 0xFF, 0xFF]
	f1 := l.frame('F1') or { panic('no F1') }
	assert f1.signals == [Mapped{'A', 8}]
	assert l.template(f1) == [protected_id(0x10), 0x00]
	// the fixture's tied frames too
	d := fixture()
	rsm := d.frame('RSM_Frm1') or { panic('no RSM_Frm1') }
	assert d.template(rsm) == [u8(0x61), 0x00]
}

fn test_a_repeated_statement_keeps_the_first() {
	src := lin13.replace('LIN_speed = 9.6 kbps;', 'LIN_speed = 9.6 kbps; LIN_speed = 19.2 kbps; LIN_protocol_version = "2.2"; LIN_description_file;').replace('Slaves: Door; }',
		'Master: X, 7 ms, 0.1 ms; Slaves: Door; } Nodes { Master: Y, 1 ms, 0.1 ms; }')
	l := parse_ldf(src) or { panic(err) }
	assert l.notes == [
		'header: LIN_speed stated twice; the second is not read',
		'header: LIN_protocol_version stated twice; the second is not read',
		'header: LIN_description_file stated twice; the second is not read',
		'Nodes Master: stated twice; the second is not read',
		'Nodes: section given twice; the second is not read',
	]
	assert (l.speed_bps or { 0 }) == 9600 && l.protocol_version == '1.3'
	assert l.master.name == 'ECU' && (l.master.time_base_ms or { 0 }) == 10
	assert l.checksum_model_for(0x10)! == .classic
}

fn test_a_signal_mapped_twice_or_off_a_byte_boundary_is_not_mapped() {
	base := leaf_doc('', '')
	l := parse_ldf(base.replace('M, 2 { Sc, 0; }', 'M, 4 { Sc, 0; Sc, 16; }').replace('G: 0x02, S, 2 { Ar, 0; }',
		'G: 0x02, S, 4 { Ar, 3; }')) or { panic(err) }
	assert 'Frames F: signal Sc is mapped twice; the second at offset 16 is not mapped' in l.notes
	assert 'Frames G: byte array Ar at offset 3 is not on a byte boundary; not mapped' in l.notes
	f := l.frame('F') or { panic('no F') }
	assert f.signals == [Mapped{'Sc', 0}]
	assert l.encode(f, {
		'Sc': Value(u64(7))
	})! == [u8(7), 0xFF, 0xFF, 0xFF]
	assert l.decode(f, [u8(1), 2, 3, 4]).len == 1
	assert (l.frame('G') or { panic('no G') }).signals == []
}

fn test_a_repeated_node_attribute_keeps_the_first() {
	base := leaf_doc('', '')
	l := parse_ldf(base.replace('configured_NAD = 0x21;', 'configured_NAD = 0x21; configured_NAD = 0x22; LIN_protocol = "1.3";').replace('configurable_frames { G = 0x1001; }',
		'configurable_frames { G = 0x1001; } configurable_frames { F = 0x1002; }')) or { panic(err) }
	assert 'Node_attributes S: configured_NAD stated twice; the second is not read' in l.notes
	assert 'Node_attributes S: LIN_protocol stated twice; the second is not read' in l.notes
	assert 'Node_attributes S: configurable_frames stated twice; the second is not read' in l.notes
	n := l.node('S') or { panic('no S') }
	assert (n.configured_nad or { 0 }) == 0x21 && n.protocol == '2.1'
	assert n.configurable_frames.map(it.name) == ['G']
}

fn test_commands_of_a_refused_table_are_not_counted() {
	base := leaf_doc('', '')
	l := parse_ldf(base.replace('Schedule_tables { T { F delay 10 ms; } }', 'Schedule_tables {
  T { AssignNAD { S } delay 10 ms; Missing delay 10 ms; }
  U { FreeFormat { 0x3C, 1, 2, 3, 4, 5, 6, 7 } delay 10 ms; }
}')) or { panic(err) }
	assert 'Schedule_tables: 1 configuration command kept for their slot time; v1 does not send them' in l.notes
	assert l.schedules.map(it.name) == ['U']
}

// One bad value is one note: a refused Master name does not make every frame of the master an
// unknown publisher, and a refused language version is not called a LIN 2.1 requirement.
fn test_one_refused_header_value_is_one_note() {
	m := parse_ldf(lin13.replace('Master: ECU, 10 ms', 'Master: ECU X, 10 ms')) or { panic(err) }
	assert m.notes == ['Nodes Master: name "ECU X" is not one value; not read']
	v := parse_ldf(lin13.replace('LIN_language_version = "1.3"', 'LIN_language_version = "3.0"')) or {
		panic(err)
	}
	assert 'header: LIN_language_version "3.0" is not a LIN version (1.x, 2.x, ISO17987:yyyy or J2602_x_y.z); not read' in v.notes
	assert 'Frames EcuCmd: length is missing and LIN_language_version was not read, so it cannot be taken from the id; not read' in v.notes
	assert !v.notes.any(it.contains('LIN 2.1 and later require'))
}

fn test_a_slave_without_node_attributes_is_said() {
	l := parse_ldf(lin20.replace('  S2 { LIN_protocol = 2.0; configured_NAD = 0x11; product_id = 0x1, 0x3; configurable_frames { MF = 0x2001; S2F = 0x2002; } }\n',
		'')) or { panic(err) }
	assert "Node_attributes S2: no attributes; its frames take the file's checksum model and it has no NAD" in l.notes
	assert !parse_ldf(lin13)!.notes.any(it.contains('no attributes')) // LIN 1.x has no such section
}
