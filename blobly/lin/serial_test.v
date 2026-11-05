module lin

fn test_a_serial_address_states_its_device_and_rate() {
	a := parse_serial('tty:/dev/ttyUSB0')!
	assert a.kind == .tty && a.path == '/dev/ttyUSB0' && a.baud == 0
	p := parse_serial('pty:/dev/pts/3@10417')!
	assert p.kind == .pty && p.path == '/dev/pts/3' && p.baud == 10417
	assert address_baud('pty:/dev/pts/3@9600') or { 0 } == 9600
	assert address_baud('tty:/dev/ttyS0') == none
	assert address_baud('inproc:x') == none
	bad := {
		'tty:':                  'names no device'
		'pty:@19200':            'names no device'
		'tty:/dev/ttyS0@':       'must be a number'
		'tty:/dev/ttyS0@fast':   'must be a number'
		'tty:/dev/ttyS0@500':    "outside LIN's"
		'tty:/dev/ttyS0@30000':  "outside LIN's"
		'tty:/dev/ttyS0@-19200': 'must be a number'
	}
	for addr, want in bad {
		parse_serial(addr) or {
			assert err.msg().contains(want), '${addr}: ${err.msg()}'
			continue
		}
		assert false, addr
	}
}

fn test_the_address_rate_and_the_configured_one_agree_or_are_refused() {
	stated := parse_serial('tty:/dev/ttyS0@9600')!
	// the default configuration takes the address's rate
	assert serial_baud(stated, Config{})! == 9600
	assert serial_baud(stated, Config{ baud: 9600 })! == 9600
	serial_baud(stated, Config{ baud: 10417 }) or {
		assert err.msg().contains('states 9600 baud, but 10417')
		bare := parse_serial('tty:/dev/ttyS0')!
		assert serial_baud(bare, Config{ baud: 10417 })! == 10417
		// 19200 stated is a statement like any other rate
		serial_baud(stated, Config{ baud: 19200 }) or {
			assert err.msg().contains('states 9600 baud, but 19200')
			return
		}
	}
	assert false
}

fn test_a_port_that_took_another_rate_is_refused() {
	// an adapter that can only make 9600 when asked for 10417 is 8 % off
	why := rate_refusal('tty:/dev/ttyUSB0@10417', .master, 10417, 9600) or { '' }
	assert why.contains('runs at 9600 baud, not 10417'), why
	// FTDI's divisor makes 10416.67: within a master's 0.5 %
	assert rate_refusal('tty:/dev/ttyUSB0@10417', .master, 10417, 10416) == none
	// 1 % off is too much for a master, not for a slave
	assert rate_refusal('tty:x', .master, 19200, 19008) != none
	assert rate_refusal('tty:x', .slave, 19200, 19008) == none
}

fn test_a_wakeup_pulse_is_within_lins_limits_at_every_rate() {
	for baud in 1000 .. 20001 {
		b := wake_byte(baud)
		mut run := 0
		for k in 0 .. 9 {
			if b == u8((u32(0xFF) << k) & 0xFF) {
				run = 1 + k
			}
		}
		assert run > 0, '${baud}: 0x${b:02X}'
		ns := i64(run) * 1_000_000_000 / i64(baud)
		assert ns >= 250_000 && ns <= 5_000_000, '${baud}: ${ns} ns'
		d := new_decoder(map[u8]Expect{}, baud)
		assert d.is_wake_pulse(b)
	}
	assert wake_byte(1000) == 0xF8 && wake_byte(19200) == 0x00
}

fn test_a_masterreq_addresses_its_nad_or_the_broadcast() {
	assert names_nad(0x0A, [u8(0x0A), 0xFF])
	assert names_nad(0x0A, [u8(0x7F)])
	assert !names_nad(0x0A, [u8(0x0B)])
	assert !names_nad(0, [u8(0)])
	assert !names_nad(0x0A, [])
}

fn test_a_pty_carries_the_break_and_a_data_ff_in_band() {
	p := pid(0x21)
	data := [u8(0xFF), 0x00, 0xFF]
	mut frame := [u8(0x55), p]
	frame << data
	frame << checksum(.enhanced, p, data)
	enc := pty_bytes(true, frame)
	assert enc[..3] == [u8(0xFF), 0x00, 0x00]
	assert enc[5..] == [u8(0xFF), 0xFF, 0x00, 0xFF, 0xFF, checksum(.enhanced, p, data)]
	mut d := new_decoder({
		u8(0x21): Expect{
			len: 3
		}
	}, 19200)
	mut got := d.feed(enc, 7)
	got << d.idle(8)
	assert got.len == 1 && got[0].errs == Errs.zero() && got[0].data == data
}

fn test_serial_is_refused_by_name_where_it_is_not_built() {
	assert serial_unsupported('tty:/dev/ttyS0') == 'lin: cannot open `tty:/dev/ttyS0`: serial LIN is Linux-only in this build'
	$if !linux {
		open('tty:/dev/ttyS0', Config{}) or {
			assert err.msg().contains('Linux-only')
			return
		}
		assert false
	}
}

fn test_a_port_counter_counts_across_its_wrap() {
	assert wrap_delta(1, 0xFFFF_FFFE) == 3
	assert wrap_delta(7, 7) == 0
	assert wrap_delta(10, 4) == 6
}

fn test_an_unknown_length_tty_response_waits_for_its_last_packet() {
	assert response_end(.tty, true, 1000) == 1000
	assert response_end(.pty, false, 1000) == 1000
	assert response_end(.tty, false, 1000) == 1000 + serial_rx_margin_ns(.tty)
}
