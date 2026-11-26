module transport

import os

// The rtnetlink read (canlink_linux.c.v) against this host's interfaces. vcan0 is the one
// scripts/setup_vcan.sh brings up; without it those checks are skipped, the rest still run.

fn have_vcan0() bool {
	return os.exists('/sys/class/net/vcan0')
}

fn test_a_vcan_reads_as_no_controller() {
	if !have_vcan0() {
		eprintln('skip: no vcan0')
		return
	}
	l := can_link_of('vcan0')
	assert l.kind == 'vcan'
	assert l.mode == .no_controller
}

fn test_a_link_that_is_not_can_or_not_there() {
	// loopback carries no IFLA_LINKINFO: no kind, no controller
	lo := can_link_of('lo')
	assert lo.kind == '' && lo.mode == .no_controller
	// no such interface: nothing read
	gone := can_link_of('blobly-nope0')
	assert gone.kind == '' && gone.mode == .unknown
}

fn test_a_listen_only_vcan_is_refused_in_software_and_says_nothing_of_a_controller() {
	if !have_vcan0() {
		eprintln('skip: no vcan0')
		return
	}
	forget_silence_claims()
	set_listen_only('vcan0', true)
	defer {
		clear_listen_only()
		forget_silence_claims()
	}
	mut b := open('vcan0')!
	defer {
		b.close()
	}
	mut refused := false
	b.send(CanFrame{ id: 0x123, data: [u8(1)] }) or {
		refused = true
		assert err is NotWritten
		assert err.msg().contains('listen-only — nothing is transmitted')
	}
	assert refused
	b.recv(0) or {}
	assert wire_silence_fault('vcan0') == none
}
