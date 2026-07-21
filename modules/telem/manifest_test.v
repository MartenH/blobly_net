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
}
