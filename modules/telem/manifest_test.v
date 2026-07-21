module telem

fn test_someip_and_ethmod_rows() {
	m := parse_manifest('# someip: service,version,port,peer
someip,0x0100,1,30490,192.168.0.190:30491
# eth modules: module,endpoint,id
ethmod,shell,method,0x1
ethmod,telemetry,cpuload,0x8005
# fb.handlers
0,app,0,Bench,on_100ms,100000
')!
	assert m.someip.service == 0x0100
	assert m.someip.version == 1
	assert m.someip.port == 30490
	assert m.someip.peer == '192.168.0.190:30491'
	assert m.shell_method == 1
	// absent sections leave the zero sentinels (service 0 = no eth identity)
	m2 := parse_manifest('# fb.handlers
0,app,0,Bench,on_100ms,100000
')!
	assert m2.someip.service == 0
	assert m2.shell_method == 0
}

fn test_someip_rows_fail_loud() {
	// a typo'd service must fail the LOAD, not silently disable the eth shell
	if _ := parse_manifest('# someip
someip,0x01G0,1,30490,peer
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'bad service hex accepted'
	}
	if _ := parse_manifest('# someip
someip,0x100,1,99999,peer
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'out-of-range port accepted'
	}
	if _ := parse_manifest('# eth modules
ethmod,shell,method,0x8001
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'event-class method id accepted'
	}
}

fn test_ethframe_and_ethlayout_rows() {
	m := parse_manifest('# someip: service,version,port,peer
someip,0x100,1,30490,192.168.0.190:30491
# eth frames: frame,id,len,dir,mode,cycle_us,e2e_id
ethframe,BenchTelem,0x8001,9,tx,cyclic,300000,0x21
ethframe,BenchCmd,0x8010,1,rx,cyclic,100000,-
# eth layout: frame,signal,field,offset,width,type
ethlayout,BenchTelem,BenchLoad,load,0,1,u8
ethlayout,BenchTelem,BenchTicks,ticks,1,4,u32
ethlayout,BenchTelem,BenchTicks,wraps,5,2,u16
# fb.handlers
0,app,0,Bench,on_100ms,100000
')!
	assert m.eth_frames.len == 2
	f := m.eth_frame_by_id(0x8001) or {
		assert false, 'BenchTelem not found by id'
		return
	}
	assert f.name == 'BenchTelem'
	assert f.length == 9
	assert f.dir == 'tx'
	assert f.cycle_us == 300000
	assert f.e2e == 0x21
	cmd := m.eth_frame_by_id(0x8010)?
	assert cmd.dir == 'rx'
	assert cmd.e2e == 0 // '-' = unprotected
	assert m.eth_frame_by_id(0x8004) == none
	// layout lookup + LE decode of a real payload (load u8, ticks u32, wraps u16)
	fields := m.eth_fields('BenchTelem')
	assert fields.len == 3
	payload := [u8(7), 0x44, 0x33, 0x22, 0x11, 0x02, 0x01, 0xAA, 0xBB]
	assert fields[0].decode(payload)? == 7
	assert fields[1].decode(payload)? == 0x11223344
	assert fields[2].decode(payload)? == 0x0102
	// a payload too short for the field decodes as absent, never as garbage
	assert fields[1].decode([u8(7), 0x44]) == none
}

fn test_ethlayout_signed_decode() {
	f := EthField{
		frame:  'F'
		signal: 'S'
		field:  'temp'
		offset: 0
		width:  2
		typ:    'i16'
	}
	assert f.decode([u8(0xFE), 0xFF])? == -2 // sign-extends from the wire width
	assert f.decode([u8(0x02), 0x00])? == 2
}

fn test_ethframe_rows_fail_loud() {
	// a typo'd frame id must fail the LOAD, not silently lose the channel's rx
	if _ := parse_manifest('ethframe,BenchTelem,0xZZ,9,tx,cyclic,300000,-
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'bad ethframe id accepted'
	}
	if _ := parse_manifest('ethframe,BenchTelem,0x8001,9,sideways,cyclic,300000,-
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'bad ethframe dir accepted'
	}
	if _ := parse_manifest('ethlayout,BenchTelem,BenchLoad,load,0,9,u8
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'out-of-range ethlayout width accepted'
	}
}

fn test_short_someip_row_rejected() {
	if _ := parse_manifest('# someip
someip,0x0100,1,30490
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'four-column someip row accepted'
	}
}

fn test_short_ethmod_shell_row_rejected() {
	if _ := parse_manifest('# eth modules
ethmod,shell,method
# fb.handlers
0,app,0,Bench,on_100ms,100000
')
	{
		assert false, 'id-less ethmod shell row accepted'
	}
	if _ := parse_manifest('# eth modules
ethmod,shell
# fb.handlers
0,app,0,Bench,on_100ms,100000
') {
		assert false, 'two-column ethmod shell row accepted'
	}
}
