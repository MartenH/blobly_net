module transport

// The controller-mode rule (canlink.v), on every OS: what a reading means, what a disagreement is
// said as, and that it goes through silence.v as a declared fault.

const all_modes = [ControllerMode.unknown, .no_controller, .normal, .listen_only]

fn test_a_link_is_a_controller_only_when_its_kind_is_can() {
	assert link_controller('can', true, 0) == .normal
	assert link_controller('can', true, 0x02) == .listen_only
	// other ctrlmode bits (loopback, FD, ...) say nothing about listening
	assert link_controller('can', true, 0x01 | 0x20) == .normal
	assert link_controller('can', true, 0x02 | 0x20) == .listen_only
	// a CAN link whose answer carried no ctrlmode is not known
	assert link_controller('can', false, 0x02) == .unknown
	for kind in ['vcan', 'vxcan', '', 'CAN', 'can0', 'slcan'] {
		assert link_controller(kind, true, 0x02) == .no_controller, kind
	}
}

fn test_every_mode_against_every_mark() {
	for mode in all_modes {
		for want in [false, true] {
			v := controller_verdict(mode, want)
			expect := match mode {
				.unknown { ModeVerdict.unread }
				.no_controller { ModeVerdict.agrees }
				.normal { if want { ModeVerdict.still_acks } else { ModeVerdict.agrees } }
				.listen_only { if want { ModeVerdict.agrees } else { ModeVerdict.cannot_send } }
			}
			assert v == expect, '${mode} want=${want}'
			r := controller_refusal('can0', '', v)
			if v in [.still_acks, .cannot_send] {
				f := r or { panic('${mode} want=${want}: nothing said') }
				assert f.declared
				assert f.why.contains('can0')
				// the remedy is the host command, never a bounce by this app
				assert f.why.contains('ip link set can0 down; ip link set can0 type can listen-only ')
				assert f.why.contains('ip link set can0 up')
				// and the status apply_silence carries reads back as the same sentence
				assert controller_reason('can0', '', verdict_status(v)) == f
			} else {
				assert r == none, '${mode} want=${want}'
			}
		}
	}
	acks := controller_refusal('can0', '', .still_acks) or { panic('none') }
	assert acks.why.contains('listen-only on') && acks.why.contains('acknowledges')
	mute := controller_refusal('can0', '', .cannot_send) or { panic('none') }
	assert mute.why.contains('listen-only off') && mute.why.contains('neither transmit nor acknowledge')
	behind := controller_refusal('can1', 'pi', .still_acks) or { panic('none') }
	assert behind.why.contains('can1 on the host of bridge "pi"')
	assert behind.why.contains('set it on the host of bridge "pi"')
	assert verdict_status(.agrees) == 0 && verdict_status(.unread) == silence_not_attempted
	assert !controller_reason('can0', '', 77).declared
}

fn test_a_disagreement_is_a_declared_fault_and_agreement_clears_it() {
	iface := 'inproc:canlink-rule'
	forget_silence_claims()
	defer {
		forget_silence_claims()
	}
	// a listen-only row on a controller that acknowledges: a declared fault, answered ok — an open
	// of a listen-only wire is refused when its reconcile errs, and SilentBus refuses its sends
	apply_controller_mode(iface, 'can0', '', .normal, true)!
	f := wire_silence_fault(iface) or { panic('no fault recorded') }
	assert f.want && f.declared && f.why.contains('ip link set can0')
	// not known: nothing recorded and nothing cleared
	apply_controller_mode(iface, 'can0', '', .unknown, true)!
	assert wire_silence_fault(iface) != none
	// no controller: nothing to hold the mark against
	apply_controller_mode(iface, 'can0', '', .no_controller, true)!
	assert wire_silence_fault(iface) != none
	// the controller set listen-only on its host: agreement, the fault goes
	apply_controller_mode(iface, 'can0', '', .listen_only, true)!
	assert wire_silence_fault(iface) == none
	// a transmitting row on a listen-only controller: the other direction, refused unwritten
	mut refused := false
	apply_controller_mode(iface, 'can0', '', .listen_only, false) or {
		refused = true
		assert err is NotWritten
	}
	assert refused
	g := wire_silence_fault(iface) or { panic('no fault recorded') }
	assert !g.want && g.declared && g.why.contains('listen-only off')
	apply_controller_mode(iface, 'can0', '', .normal, false)!
	assert wire_silence_fault(iface) == none
	assert !mode_holds_against(.unknown) && !mode_holds_against(.no_controller)
	assert mode_holds_against(.normal) && mode_holds_against(.listen_only)
}

fn test_the_log_narrates_a_fault_once_and_its_clearing() {
	acks := SilenceFault{
		want:     true
		why:      'the controller of can0 is not listen-only'
		declared: true
	}
	assert silence_fault_change('can0', none, none) == none
	assert silence_fault_change('can0', acks, acks) == none
	assert silence_fault_change('can0', none, acks)? == 'can0: marked listen-only, but the controller of can0 is not listen-only'
	mute := SilenceFault{
		want: false
		why:  'x'
	}
	assert silence_fault_change('can0', acks, mute)? == 'can0: transmit-enabled, but x'
	assert silence_fault_change('can0', acks, none)? == 'can0: the controller now agrees with the row (listen-only)'
}

fn test_a_standing_pair_refuses_only_a_transmitting_row_on_a_listen_only_controller() {
	for mode in all_modes {
		for want in [false, true] {
			mut refused := false
			controller_send_refusal('can0', 'pi', mode, want) or {
				refused = true
				assert err is NotWritten
				assert err.msg().contains('can0 on the host of bridge "pi" is listen-only')
			}
			assert refused == (mode == .listen_only && !want), '${mode} want=${want}'
		}
	}
}

fn test_a_wire_s_fault_is_forgotten_when_its_last_handle_closes() {
	iface := 'inproc:canlink-holders'
	forget_silence_claims()
	defer {
		forget_silence_claims()
	}
	controller_wire_opened(iface)
	controller_wire_opened(iface)
	apply_controller_mode(iface, 'can0', '', .normal, true)!
	assert wire_silence_fault(iface) != none
	controller_wire_closed(iface)
	assert wire_silence_fault(iface) != none, 'forgotten while a handle is still open'
	controller_wire_closed(iface)
	assert wire_silence_fault(iface) == none
	// a later open counts afresh
	controller_wire_opened(iface)
	apply_controller_mode(iface, 'can0', '', .listen_only, false) or {}
	assert wire_silence_fault(iface) != none
	controller_wire_closed(iface)
	assert wire_silence_fault(iface) == none
}
