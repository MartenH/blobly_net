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
	// EVERY ADAPTER IS CLASSIFIED, and a name nobody classified fails here.
	//
	// This replaces three tautologies -- `assert carries || !carries` and friends -- which were
	// true of every boolean and so passed for an adapter that fell through all three predicates,
	// which is the exact omission this file says it guards (codex round 3 on #204, and quite
	// right). The predicates themselves cannot tell "no" from "never heard of it": both answer
	// false. So the classification is stated HERE, and a newly registered adapter fails until
	// somebody says which group it belongs to -- at which point the assertions below check that
	// the predicates were told the same thing.
	for a in adapters {
		assert a in software_adapters || a in kernel_adapters || a in vendor_adapters
			|| a in non_can_adapters, '${a} is registered but unclassified — say which kind it is here, and check the capability predicates were told too'
	}
	// The vendor backends this app opens itself: the address carries the rate, because no driver
	// or kernel is going to be asked for it.
	for a in vendor_adapters {
		assert a in adapters, '${a} is a backend transport can open but the project cannot name'
		assert transport.adapter_configures_bitrate(a), '${a} takes its rate in the address'
	}
	// And the ones where something else owns the timing. Asserted in the NEGATIVE, which is what
	// makes the vendor list above mean anything: without this, adding every adapter to
	// adapter_configures_bitrate would satisfy the loop above.
	for a in kernel_adapters {
		assert !transport.adapter_configures_bitrate(a), '${a} is a kernel interface — `ip link` sets its rate, not the address'
	}
	for a in software_adapters {
		assert !transport.adapter_configures_bitrate(a), '${a} is a software bus with no bit timing to configure'
	}
	for a in non_can_adapters {
		assert !transport.adapter_carries_fd(a), '${a} is not a CAN bus and cannot carry a CAN-FD frame'
		assert !transport.adapter_configures_bitrate(a), '${a} has no bitrate'
	}
}

// The four kinds of adapter, which is what the predicates are ABOUT. Kept beside the test rather
// than in the module: this is the test's own model of the registry, and it has to be able to
// disagree with the code for the check above to be worth anything.
const software_adapters = ['virtual', 'udp'] // driver-free, no bit timing exists

const kernel_adapters = ['vcan', 'socketcan'] // the OS owns the timing

const vendor_adapters = ['pcan', 'kvaser', 'vector', 'cansub'] // the address carries the rate

const non_can_adapters = ['doip'] // not a CAN bus at all

// The hardware whose CONTROLLER this app can actually silence — Vector through `,silent` on the
// port, CANsub through `listen_only` in the PHY object. That is what makes a default tick honest
// rather than a promise only half kept, which is why it is a shorter list than `vendor_adapters`.
const silenced_at_the_transceiver = ['vector', 'cansub']

// The three that carry CAN-FD, and the one that does not. Stated as a list rather than derived, so
// that adding a backend forces a decision here instead of inheriting `else { true }` unnoticed --
// which is exactly how `cansub` became FD-capable without anybody saying so.
fn test_fd_capability_is_declared_per_backend() {
	assert transport.adapter_carries_fd('vector')
	assert transport.adapter_carries_fd('kvaser')
	assert transport.adapter_carries_fd('cansub')
	assert transport.adapter_carries_fd('pcan'), 'PCAN carries FD since #217; it was the last CAN backend that could not'
	assert !transport.adapter_carries_fd('doip'), 'DoIP is not a CAN bus'

	assert transport.adapter_configures_data_phase('vector')
	assert transport.adapter_configures_data_phase('kvaser')
	assert transport.adapter_configures_data_phase('cansub')
	assert transport.adapter_configures_data_phase('pcan'), 'CAN_InitializeFD takes both phases, so the address carries both'
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

// AN ADAPTER THE ENGINE KNOWS MUST BE ONE A USER CAN PICK. This is the same half-registration the
// rest of this file guards, one layer up: CANsub was added to `adapters`, to compose_iface, to
// decompose_iface and to all three capability predicates, and the GUI kept its OWN hardcoded
// picker list — so the backend was complete, tested, and reachable only by editing the project
// file in a text editor (codex round 1 on #204).
//
// The lists are here rather than in the GUI precisely so this test can see them. It cannot check
// that an adapter is on the RIGHT platform; it can check that it is on one, which is how this got
// in.
fn test_every_registered_adapter_is_offered_somewhere() {
	for a in adapters {
		assert a in windows_adapters || a in linux_adapters, '${a} is registered but no platform offers it — the only way to reach it is to hand-edit the project file'
	}
}

// And the other direction: a picker cannot offer a name the project cannot compose, which would
// produce a row that fails at Start with "unknown adapter" long after the editor accepted it.
fn test_no_platform_offers_an_adapter_the_project_cannot_name() {
	for a in windows_adapters {
		assert a in adapters, 'the Windows picker offers ${a}, which is not a registered adapter'
	}
	for a in linux_adapters {
		assert a in adapters, 'the Linux picker offers ${a}, which is not a registered adapter'
	}
}

// platform_adapters must answer with one of the two lists, not a third one assembled inline.
fn test_platform_adapters_is_one_of_the_declared_lists() {
	got := platform_adapters()
	assert got == windows_adapters || got == linux_adapters, 'platform_adapters returned a list that is neither declared one: ${got}'
}

// A NEW ROW ON HARDWARE STARTS SILENT, and that rule has to be answered for every adapter — not
// only the one it was first written for.
//
// It lived as two hardcoded `== 'vector'` comparisons in cmd/blobly_net, so exposing CANsub in the
// picker made the manual route the unsafe one while Discover stayed careful: a fresh row went on a
// possibly-live bus able to ACK, at a 500 kbit/s guess nobody had confirmed (codex round 5 on
// #204). It is a property of the adapter, so it belongs beside the other adapter properties, where
// this can hold it.
fn test_every_adapter_that_can_silence_its_controller_starts_silent() {
	for a in silenced_at_the_transceiver {
		assert adapter_starts_silent(a), '${a} is hardware that may already be wired to a running vehicle — a new row on it must not transmit until somebody confirms the rate'
	}
}

// PCAN and Kvaser are hardware too, and deliberately NOT in that list: this app cannot put their
// controllers into listen-only, only refuse to transmit from inside this process. Defaulting a row
// to a tick that half-works would be a promise the transceiver does not keep, and changing what
// existing PCAN and Kvaser rows do is not something a CANsub PR gets to decide. Named here so the
// distinction is a stated one rather than an oversight.
fn test_the_hardware_we_cannot_silence_is_a_deliberate_exception() {
	for a in ['pcan', 'kvaser'] {
		assert a in vendor_adapters
		assert a !in silenced_at_the_transceiver
		assert !adapter_starts_silent(a), '${a} cannot silence its controller, so a default tick would promise what the transceiver will not do'
	}
}

// Nothing outside the vendor adapters may start silent: a software bus that defaulted to refusing
// its own sends would look broken for a reason nobody would think to check.
fn test_only_hardware_starts_silent() {
	for a in adapters {
		if adapter_starts_silent(a) {
			assert a in vendor_adapters, '${a} starts silent but is not hardware'
		}
	}
}

// And the ones with nothing to silence must NOT start silent, or the tick means nothing and gets
// ignored where it does matter. A software bus has no transceiver; a SocketCAN interface is
// brought up by `ip link` with a rate its operator already chose.
fn test_adapters_with_no_transceiver_do_not_start_silent() {
	for a in software_adapters {
		assert !adapter_starts_silent(a), '${a} has no transceiver to silence'
	}
	for a in kernel_adapters {
		assert !adapter_starts_silent(a), '${a} is configured outside this app, at a rate its operator chose'
	}
	for a in non_can_adapters {
		assert !adapter_starts_silent(a), '${a} is not a CAN bus'
	}
}

// ---- changing a row's adapter (#204 round 6) -----------------------------

// SWITCHING BETWEEN TWO ADAPTERS THAT BOTH START SILENT IS STILL A CHANGE OF HARDWARE. Expressed
// in the GUI as "starts silent now and did not before", this missed exactly that pair: a
// transmit-enabled Vector row switched to CANsub kept `listen_only = false` and the new controller
// opened able to ACK, at a rate nobody had confirmed for it.
fn test_switching_between_two_silent_starting_adapters_re_arms_silence() {
	assert adapter_change_starts_silent('vector', 'cansub')
	assert adapter_change_starts_silent('cansub', 'vector')
}

fn test_becoming_hardware_re_arms_silence() {
	for was in ['virtual', 'udp', 'vcan', 'socketcan', 'pcan', 'kvaser', 'doip'] {
		for now in silenced_at_the_transceiver {
			assert adapter_change_starts_silent(was, now), '${was} -> ${now} is new hardware at an unconfirmed rate'
		}
	}
}

// Not a change is not a change: re-selecting the same adapter must not silently re-tick a box the
// operator deliberately cleared.
fn test_reselecting_the_same_adapter_changes_nothing() {
	for a in adapters {
		assert !adapter_change_starts_silent(a, a), '${a} -> ${a} is not a change of hardware'
	}
	// Spelling is not a change either — the picker and a hand-edited file can disagree on case.
	assert !adapter_change_starts_silent('CANSUB', 'cansub')
}

// And moving to an adapter that does not start silent never arms it.
fn test_moving_to_an_adapter_that_does_not_start_silent_arms_nothing() {
	for now in adapters {
		if now in silenced_at_the_transceiver {
			continue
		}
		for was in adapters {
			assert !adapter_change_starts_silent(was, now), '${was} -> ${now} must not arm listen-only'
		}
	}
}
