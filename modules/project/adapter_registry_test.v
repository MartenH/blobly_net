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
