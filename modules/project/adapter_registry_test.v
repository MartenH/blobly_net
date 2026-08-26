module project

import transport

// Every adapter this project can name has to be ANSWERED by the capability predicates, and the
// answers have to agree with each other. This file exists because the same half-registration has
// now happened three times:
//
//   - Kvaser gained CAN-FD (#200) and `adapter_configures_data_phase` was not told, so a `canfd`
//     Kvaser row composed a classic address, opened classic, and refused every FD frame -- while
//     the warning that would have said so went quiet, because `adapter_carries_fd` HAD been told;
//   - the CANsub backend landed with `destination_key_for`'s list updated and modules/project's
//     five copies of the same list not, so its addresses carried a rate the project did not
//     compose;
//   - and `project.adapters` itself did not list `cansub`, so the backend could not be selected.
//
// Each was one list updated out of several. A test that walks `adapters` cannot stop somebody
// answering wrongly, but it can stop them answering by omission -- which is how all three got in.

// A backend that configures a DATA phase must configure a nominal rate as well: the data phase is
// spelled `@<arb>/<data>`, so there is no address that carries the second without the first.
fn test_a_data_phase_implies_a_nominal_rate() {
	for a in adapters {
		if transport.adapter_configures_data_phase(a) {
			assert transport.adapter_configures_bitrate(a), '${a} configures a data phase but not a rate — its address cannot spell one'
		}
	}
}

// A backend that configures a data phase must also be able to CARRY an FD frame. The reverse does
// not hold: SocketCAN carries FD while `ip link` sets its data phase.
fn test_configuring_a_data_phase_implies_carrying_fd() {
	for a in adapters {
		if transport.adapter_configures_data_phase(a) {
			assert transport.adapter_carries_fd(a), '${a} configures a data phase but is not listed as FD-capable'
		}
	}
}

// The classifications are per adapter NAME, so every name the project can hold must be one this
// module recognises -- a typo'd or renamed adapter would otherwise answer the `else` branch of
// each predicate and look like a legitimate software bus.
fn test_every_declared_adapter_is_known_to_transport() {
	for a in adapters {
		// Not an assertion about the answer, only that asking is meaningful: `doip` is not CAN at
		// all and correctly answers false to everything.
		carries := transport.adapter_carries_fd(a)
		rate := transport.adapter_configures_bitrate(a)
		data := transport.adapter_configures_data_phase(a)
		assert carries || !carries // total
		assert rate || !rate
		assert data || !data
	}
	// The vendor backends this app opens itself, named explicitly so a REMOVAL is as loud as an
	// addition would be.
	for a in ['pcan', 'kvaser', 'vector', 'cansub'] {
		assert a in adapters, '${a} is a backend transport can open but the project cannot name'
		assert transport.adapter_configures_bitrate(a), '${a} takes its rate in the address'
	}
}

// The three that carry CAN-FD, and the one that does not. Stated as a list rather than derived, so
// that adding a backend forces a decision here instead of inheriting `else { true }` unnoticed --
// which is exactly how `cansub` became FD-capable without anybody saying so.
fn test_fd_capability_is_declared_per_backend() {
	assert transport.adapter_carries_fd('vector')
	assert transport.adapter_carries_fd('kvaser')
	assert transport.adapter_carries_fd('cansub')
	assert !transport.adapter_carries_fd('pcan'), 'PCAN refuses an FD frame rather than truncating'
	assert !transport.adapter_carries_fd('doip'), 'DoIP is not a CAN bus'

	assert transport.adapter_configures_data_phase('vector')
	assert transport.adapter_configures_data_phase('kvaser')
	assert transport.adapter_configures_data_phase('cansub')
	assert !transport.adapter_configures_data_phase('pcan')
	assert !transport.adapter_configures_data_phase('socketcan'), '`ip link` sets its data phase, not us'
	assert !transport.adapter_configures_data_phase('vcan')
}

// COMPOSE AND DECOMPOSE ARE THE OTHER HALF, and the half the first version of this file missed.
// The predicates above would all have answered correctly for `cansub` while compose_iface still
// produced a bare `e5a16adf/1` with no scheme — opened as a SocketCAN name on Linux and refused on
// Windows — and decompose_iface read a `cansub:` address back as adapter `socketcan`. A backend
// can be fully classified and still be unreachable, which is exactly what half-registration looks
// like the third time.
fn test_every_adapter_round_trips_through_compose() {
	// address shapes that are realistic for each, since compose is not required to invent one
	samples := {
		'virtual':   'CAN1'
		'vcan':      'vcan0'
		'socketcan': 'can0'
		'udp':       '239.63.42.1:20000'
		'pcan':      'PCAN_USBBUS1'
		'kvaser':    '0'
		'vector':    '1'
		'cansub':    'e5a16adf/1'
		'doip':      '127.0.0.1:13400'
	}
	for a in adapters {
		addr := samples[a] or {
			assert false, 'adapters lists ${a} but this test has no sample address for it — add one'
			continue
		}
		iface := compose_iface(a, addr)
		assert iface != '', '${a} composed nothing'
		back_adapter, back_addr := decompose_iface(iface)
		assert back_adapter == a, '${a}: composed "${iface}" but decomposed as "${back_adapter}"'
		assert back_addr == addr, '${a}: address "${addr}" came back as "${back_addr}"'
	}
}

// A rate suffix is stripped by decompose for every adapter that carries one, because the rate
// lives in the channel's own field and re-appending it at open would produce `…@500000@500000`.
fn test_a_rate_suffix_does_not_survive_decompose() {
	for a in adapters {
		if !transport.adapter_configures_bitrate(a) {
			continue
		}
		base := match a {
			'pcan' { 'PCAN_USBBUS1' }
			'kvaser' { '0' }
			'vector' { '1' }
			'cansub' { 'e5a16adf/1' }
			else { continue }
		}

		_, addr := decompose_iface(compose_iface(a, base) + '@500000')
		assert addr == base, '${a}: the rate suffix survived decompose as "${addr}"'
	}
}
