module lin

fn good(src Src) Frame {
	return Frame{
		...interpret(0x21, [u8(1), 2, 3, 4, 0x94], Expect{ len: 4 })
		src: src
	}
}

fn test_origin() {
	assert origin_of(Frame{ src: .sim }) == 'TX-S'
	assert origin_of(Frame{ src: .tester }) == 'TX'
	assert origin_of(Frame{ src: .remote }) == 'RX'
}

fn test_bus_traffic_is_a_clean_remote_response() {
	f := good(.remote)
	assert f.errs == Errs.zero()
	assert is_bus_traffic(f)
	assert !is_bus_traffic(Frame{ ...f, src: .sim })
	assert !is_bus_traffic(Frame{ ...f, src: .tester })
	assert !is_bus_traffic(Frame{ ...f, ours: true })
	assert !is_bus_traffic(Frame{ ...f, errs: Errs.checksum })
	assert !is_bus_traffic(interpret(0x21, [], none)) // the master's unanswered header
	assert !is_bus_traffic(Frame{ event: .wakeup })
}

fn test_key_suffix() {
	f := good(.remote)
	assert key_suffix(f) == ''
	assert key_suffix(Frame{ ...f, errs: Errs.checksum }) == '/checksum'
	assert key_suffix(interpret(0x21, [], none)) == '/no_response'
	assert key_suffix(Frame{ event: .wakeup }) == '/wakeup'
}

fn test_reading() {
	f := good(.remote)
	assert reading(f) == '0x21 [4] 01 02 03 04 cs 0x94 enhanced'
	mut bad := interpret(0x21, [u8(1), 2, 3, 4, 0x95], Expect{ len: 4 })
	assert reading(bad) == '0x21 [4] 01 02 03 04 cs 0x95 enhanced !checksum'
	bad.errs.set(.collision)
	assert reading(bad) == '0x21 [4] 01 02 03 04 cs 0x95 enhanced !checksum !collision'
	assert reading(interpret(0x21, [], none)) == '0x21 no response'
	assert reading(interpret(0x21, [u8(7)], Expect{ len: 4 })) == '0x21 [1] 07 !short'
	mut raw := sleep_data()
	raw << 0x00
	s := interpret(0x3C, raw, none)
	assert reading(s) == '0x3C [8] 00 FF FF FF FF FF FF FF cs 0x00 classic sleep'
	assert reading(Frame{ errs: Errs.sync }) == 'header !sync'
}

fn test_errs_names() {
	mut e := Errs.zero()
	assert e.names() == []
	e.set(.bit)
	e.set(.sync)
	assert e.names() == ['sync', 'bit']
}

fn test_has_id() {
	assert has_id(Frame{
		id:  0x21
		raw: [u8(1), 0x94]
	})
	assert has_id(Frame{
		id:   0x21
		errs: .no_response
	})
	assert !has_id(Frame{
		event: .wakeup
	})
	assert !has_id(Frame{
		errs: .sync
	})
	assert !has_id(Frame{
		pid:  0x61
		errs: .parity
	})
}
