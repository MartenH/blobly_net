module transport

import time

// The address, and the identity derived from it. Both are string logic, so both are checked here
// rather than discovered on a bench with four channels running.

fn test_a_plain_address() {
	s := parse_cansub_iface('cansub:e5a16adf/1')!
	assert s.id == 'e5a16adf'
	assert s.channel == 1
	assert s.arb == 500000, 'the default rate should apply when none is named'
	assert !s.fd
	assert s.data == 0, 'a classic address must not configure a data phase'
}

fn test_an_address_with_a_bitrate() {
	s := parse_cansub_iface('cansub:e5a16adf/3@250000')!
	assert s.channel == 3
	assert s.arb == 250000
	assert !s.fd
}

// The data rate IS the FD flag, the same rule the Vector address follows — one thing to say, so
// there is no address that claims FD while naming a single rate.
fn test_a_data_rate_asks_for_fd() {
	s := parse_cansub_iface('cansub:e5a16adf/2@500000/2000000')!
	assert s.fd
	assert s.arb == 500000
	assert s.data == 2000000
}

fn test_fd_at_the_same_rate_is_a_real_configuration() {
	s := parse_cansub_iface('cansub:e5a16adf/1@500000/500000')!
	assert s.fd, '64-byte payloads with no bit-rate switch is a configuration, and must be spellable'
	assert s.data == 500000
}

// The device numbers its channels 1..4 and answers 404 outside that — several seconds into an
// open, as an unhelpful HTTP error. Caught while it is still a string somebody typed.
fn test_channel_zero_is_refused() {
	parse_cansub_iface('cansub:e5a16adf/0') or {
		assert err.msg().contains('1 to 4')
		return
	}
	assert false, 'accepted channel 0, which the device does not have'
}

fn test_addresses_that_make_no_sense_are_refused() {
	for bad in ['cansub:e5a16adf', 'cansub:/1', 'cansub:e5a16adf/x', 'cansub:e5a16adf/1@abc',
		'cansub:e5a16adf/1@250000@500000', 'vector:1'] {
		parse_cansub_iface(bad) or { continue }
		assert false, 'accepted "${bad}"'
	}
}

// A data phase slower than arbitration is refused by the shared rule — the data phase is the fast
// one, and a controller asked for the reverse produces a bus nothing else can read.
fn test_a_slower_data_phase_is_refused() {
	parse_cansub_iface('cansub:e5a16adf/1@500000/125000') or { return }
	assert false, 'accepted a data phase slower than arbitration'
}

// IDENTITY. The wire is the device and the channel; the rate is a setting on it. Keyed with the
// rate, a 250k row and a 500k row on one channel would be two wires that never meet, and the
// check that exists to find exactly that disagreement could not fire.
fn test_the_rate_is_not_part_of_the_wire() {
	a := wire_key_for('cansub', 'cansub:e5a16adf/1@250000')
	b := wire_key_for('cansub', 'cansub:e5a16adf/1@500000')
	assert a == b, 'one channel at two rates must be one wire: ${a} vs ${b}'
}

fn test_different_channels_are_different_wires() {
	a := wire_key_for('cansub', 'cansub:e5a16adf/1@500000')
	b := wire_key_for('cansub', 'cansub:e5a16adf/2@500000')
	assert a != b
}

fn test_different_devices_are_different_wires() {
	a := wire_key_for('cansub', 'cansub:e5a16adf/1@500000')
	b := wire_key_for('cansub', 'cansub:aabbccdd/1@500000')
	assert a != b, 'two devices are not one wire — a bench has several'
}

// Two spellings of one address are one destination, or a project mapping the same channel twice
// goes undetected.
fn test_spelling_does_not_split_a_destination() {
	a := destination_key_for('cansub', 'cansub:E5A16ADF/1@500000')
	b := destination_key_for('cansub', ' cansub:e5a16adf/1@0500000 ')
	assert a == b, '${a} vs ${b}'
}

// Classic and FD on one channel are the same WIRE — so the conflict check groups them and can
// report the disagreement — but NOT the same destination, so nothing hands an FD opener a
// connection configured for classic.
fn test_classic_and_fd_share_a_wire_but_not_a_destination() {
	classic := 'cansub:e5a16adf/1@500000'
	fd := 'cansub:e5a16adf/1@500000/2000000'
	assert wire_key_for('cansub', classic) == wire_key_for('cansub', fd)
	assert destination_key_for('cansub', classic) != destination_key_for('cansub', fd)
}

// A CANsub reports its own transmissions back over the same socket. Told otherwise, every frame
// this tester sends would be filed a second time as the ECU's — the defect #139 fixed for Vector.
fn test_a_cansub_echoes_its_own_sends() {
	assert echoes_own_sends('cansub:e5a16adf/1@500000')
}

// It refuses an out-of-range frame rather than truncating it, like the other hardware backends —
// a malformed frame is something a bench wants rejected, not quietly turned into a valid
// different one.
fn test_a_cansub_does_not_clamp() {
	assert !clamps_to_classic('cansub:e5a16adf/1@500000')
}

// Recognised on BOTH platforms, unlike the vendor-DLL backends. On Linux `pcan:bench` is an
// ordinary SocketCAN name, but a CANsub is an HTTP server on the end of a USB cable and means the
// same thing everywhere.
fn test_a_cansub_is_hardware_on_every_platform() {
	assert vendor_iface('cansub:e5a16adf/1'), 'a CANsub is not a SocketCAN name on Linux'
}

// The project layer asks by ADAPTER whether FD can reach the wire. A CANsub can.
fn test_the_adapter_carries_fd() {
	assert adapter_carries_fd('cansub')
}

// A CLASSIC ROW IS VALIDATED TOO. Unlike a vendor driver that will produce any sane nominal rate,
// the CANsub derives its timing from an 80 MHz clock that must divide EXACTLY — so it is the first
// adapter here that can refuse a plain classic bitrate. 333333 bit/s passed the editor's
// digits-only check and was refused only at Start (codex round 1 on #204).
fn test_a_classic_rate_the_clock_cannot_divide_is_refused() {
	why := cansub_address_error('cansub:1A2B3C4D/1@333333') or {
		assert false, '333333 bit/s does not divide 80 MHz and must be refused'
		return
	}
	assert why.contains('333333'), 'the refusal must name the rate: ${why}'
}

fn test_a_classic_rate_the_clock_can_divide_is_accepted() {
	for r in [125_000, 250_000, 500_000, 1_000_000] {
		if why := cansub_address_error('cansub:1A2B3C4D/1@${r}') {
			assert false, '${r} bit/s is an ordinary CAN rate and must be accepted: ${why}'
		}
	}
}

// recv(-1) MEANS BLOCK, per the Bus contract — `cmd/can_smoke` is one caller that uses it. Adding
// the negative to the clock put the deadline in the past, so the one caller asking to wait forever
// got `timeout` immediately (codex round 1 on #204).
fn test_a_negative_timeout_blocks_rather_than_expiring() {
	now := i64(1_000_000)
	deadline := now + i64(-1) // what recv computes for recv(-1)
	slice := cansub_wait_slice(-1, deadline, now) or {
		assert false, 'recv(-1) must block, not expire'
		return
	}
	assert slice == cansub_poll_ms, 'a blocking caller waits a full poll interval at a time'
	// And it keeps blocking however long it has already been waiting.
	later := cansub_wait_slice(-1, deadline, now + 10_000) or {
		assert false, 'a blocking caller never expires'
		return
	}
	assert later == cansub_poll_ms
}

// The poll interval is a CEILING, not a floor: it exists so an idle receiver notices a dead
// socket. Parking the whole 200 ms regardless made recv(5) — used by polling and shutdown loops
// throughout this repo — forty times slower than the interface promises.
fn test_a_short_timeout_is_not_rounded_up_to_the_poll_interval() {
	now := i64(1_000_000)
	for t in [1, 5, 20, 50, 199] {
		slice := cansub_wait_slice(t, now + i64(t), now) or {
			assert false, 'recv(${t}) has budget left and must wait'
			return
		}
		assert slice == i64(t), 'recv(${t}) waited ${slice} ms'
	}
}

fn test_a_long_timeout_is_capped_at_the_poll_interval() {
	now := i64(1_000_000)
	slice := cansub_wait_slice(5000, now + 5000, now) or {
		assert false, 'budget remains'
		return
	}
	assert slice == cansub_poll_ms, 'a long wait is still broken into poll intervals so the socket is checked'
}

fn test_an_expired_budget_reports_timeout() {
	now := i64(1_000_000)
	if _ := cansub_wait_slice(50, now - 1, now) {
		assert false, 'a deadline in the past is a timeout'
	}
	if _ := cansub_wait_slice(0, now, now) {
		assert false, 'recv(0) polls once and does not wait'
	}
}

// AND THE CEILING, which was not checked. A `.4` has four channels; `cansub:<id>/5` parsed
// cleanly, so `address_config_error` accepted it too and the editor SAVED the row — the refusal
// arrived as an HTTP 404 several seconds into Start, from a project that had looked valid
// (codex round 2 on #204). The floor had this test; the ceiling had none.
fn test_a_channel_above_the_devices_last_is_refused() {
	for ch in [5, 9, 64] {
		if _ := parse_cansub_iface('cansub:e5a16adf/${ch}') {
			assert false, 'channel ${ch} does not exist on a CANsub.4'
		}
	}
}

fn test_every_channel_the_device_has_is_accepted() {
	for ch in 1 .. cansub_channels + 1 {
		s := parse_cansub_iface('cansub:e5a16adf/${ch}') or {
			assert false, 'channel ${ch} is one the device has: ${err}'
			return
		}
		assert s.channel == ch
	}
}

// TWO SPELLINGS OF ONE WIRE must compare equal, or `shared_open` refuses the second alias its
// transmit handle over a difference that does not exist. The wire key already folded them
// together; the spec comparison beside it did not (codex round 2 on #204).
fn test_spellings_of_one_address_canonicalise_together() {
	a := cansub_canonical_spec('cansub:E5A16ADF/1@500000')
	b := cansub_canonical_spec('cansub:e5a16adf/01@500000')
	assert a == b, '${a} != ${b}'
}

fn test_canonicalisation_still_separates_different_settings() {
	base := cansub_canonical_spec('cansub:e5a16adf/1@500000')
	assert cansub_canonical_spec('cansub:e5a16adf/2@500000') != base, 'a different channel is a different wire'
	assert cansub_canonical_spec('cansub:e5a16adf/1@250000') != base, 'a different rate is a different setting'
	assert cansub_canonical_spec('cansub:e5a16adf/1@500000/2000000') != base, 'a data phase is a different setting'
	assert cansub_canonical_spec('cansub:aaaaaaaa/1@500000') != base, 'a different device is a different wire'
}

// An address that does not parse has no canonical form to give, and must not collapse into one
// with any other unparseable address — that would let two unrelated bad strings share a handle.
fn test_an_unparseable_address_is_its_own_canonical_form() {
	x := cansub_canonical_spec('cansub:nonsense')
	y := cansub_canonical_spec('cansub:other-nonsense')
	assert x != y
}

// recv(0) IS A NON-BLOCKING POLL, not "do nothing". Every other bus here answers it by looking at
// what is already queued and returning it. Derived from the deadline alone it came out as an
// expired budget, so a caller draining with a zero timeout was told the queue was empty while
// frames sat in it — and the test beside this one asserted the poll behaviour in a comment while
// the code did not do it (codex round 3 on #204).
fn test_a_zero_timeout_still_probes_the_queue_once() {
	now := i64(1_000_000)
	slice := cansub_first_wait(0, now, now) or {
		assert false, 'recv(0) must look at the queue before giving up'
		return
	}
	assert slice == 0, 'it looks, and then gives up immediately — it does not wait'
}

// And only ONCE: the second slice of a recv(0) has no budget left, or the loop would spin.
fn test_a_zero_timeout_does_not_poll_twice() {
	now := i64(1_000_000)
	if _ := cansub_wait_slice(0, now, now) {
		assert false, 'after the first probe, recv(0) is out of budget'
	}
}

// A positive timeout is unaffected by the first-slice rule.
fn test_the_first_slice_of_a_positive_timeout_is_the_ordinary_one() {
	now := i64(1_000_000)
	a := cansub_first_wait(20, now + 20, now) or {
		assert false, 'budget remains'
		return
	}
	b := cansub_wait_slice(20, now + 20, now) or {
		assert false, 'budget remains'
		return
	}
	assert a == b && a == 20
}

// And a blocking recv is still blocking on its first slice.
fn test_the_first_slice_of_a_blocking_recv_blocks() {
	now := i64(1_000_000)
	slice := cansub_first_wait(-1, now - 1, now) or {
		assert false, 'recv(-1) blocks'
		return
	}
	assert slice == cansub_poll_ms
}

// The decoder already preserves the device's TX bit in CansubRecord. The shared hub must see it
// too, or it cannot exclude the logical handle that originated the send and the simulation can
// receive its own frame. This stays a private transport seam: ordinary Bus.recv still projects a
// CanFrame for callers that do not share the physical connection.
fn test_the_shared_receive_seam_preserves_a_tx_acknowledgement() {
	mut b := CansubBus{
		iface: 'cansub:test/1'
		rx:    chan CansubRecord{cap: 3}
	}
	b.rx <- CansubRecord{
		is_error: true
		err:      .ack_err
	}
	b.rx <- CansubRecord{
		frame: CanFrame{
			id:   0x123
			data: [u8(0xAB)]
		}
		tx:    true
	}

	got := b.recv_shared(0) or {
		assert false, 'the queued TX acknowledgement must be returned: ${err}'
		return
	}
	assert got.tx_ack
	assert got.frame.id == 0x123
	assert got.frame.data == [u8(0xAB)]
	assert b.diagnostics().contains('1 controller error'), 'error records skipped on the way to the frame must still be counted'
	assert b.reports_tx_ack()
}

fn test_public_cansub_recv_still_projects_a_plain_frame() {
	mut b := CansubBus{
		iface: 'cansub:test/1'
		rx:    chan CansubRecord{cap: 1}
	}
	b.rx <- CansubRecord{
		frame: CanFrame{
			id: 0x456
		}
		tx:    true
	}

	got := b.recv(0) or {
		assert false, 'the queued frame must be returned: ${err}'
		return
	}
	assert got.id == 0x456
}

// ---- reading the device's health reply (#204 round 13) -------------------

// WHITESPACE IS LEGAL JSON, and matching `"key":"` exactly meant a device that pretty-printed its
// reply parsed as nothing at all — after which the caller treated "no answer" as an answer and
// kept the previous verdict. The device does not format that way today; a firmware update is not
// something to find out about through a health indicator stuck on ok.
fn test_a_json_field_is_found_however_it_is_spaced() {
	for body in ['{"state":"bus_off"}', '{"state": "bus_off"}', '{"state" : "bus_off"}',
		'{ "state":\t"bus_off" }', '{\n  "state": "bus_off"\n}'] {
		got := extract_json_string(body, 'state') or {
			assert false, 'did not parse: ${body}'
			return
		}
		assert got == 'bus_off', '${body} -> ${got}'
	}
}

fn test_the_right_field_is_found_among_others() {
	body := '{"name": "CAN1", "state": "error_passive", "bitrate": 500000}'
	assert extract_json_string(body, 'state')? == 'error_passive'
	assert extract_json_string(body, 'name')? == 'CAN1'
}

// A field that is absent, or whose value is not a string, is NOT an answer — the caller counts
// that as a missed poll rather than keeping a stale verdict.
fn test_a_missing_or_non_string_field_is_no_answer() {
	assert extract_json_string('{"other":"x"}', 'state') == none
	assert extract_json_string('{"state":500000}', 'state') == none, 'a number is not the state'
	assert extract_json_string('{"state"}', 'state') == none
	assert extract_json_string('', 'state') == none
	assert extract_json_string('{"state":', 'state') == none, 'a truncated body must not parse'
}

// And a key that merely CONTAINS the name is not the key.
fn test_a_similar_key_is_not_the_key() {
	// `"substate"` ends with `state"`, so a naive search for the name would land inside it.
	body := '{"substate":"wrong","state":"bus_off"}'
	assert extract_json_string(body, 'state')? == 'bus_off'
}

// A DEVICE ID BECOMES A HOSTNAME: `cansub_host` builds `<id>-usb.local` and hands it to mDNS. An
// id that is not a legal hostname label cannot resolve, and checked only for emptiness it was
// accepted by the editor AND by the shared start check, then failed several seconds into an open
// as a network error (codex round 14 on #204).
fn test_a_device_id_that_cannot_be_a_hostname_is_refused() {
	for bad in ['bad id', 'a_b', 'dev.ice', '-lead', 'trail-', 'has/slash', 'sp ace'] {
		if _ := parse_cansub_iface('cansub:${bad}/1') {
			assert false, '"${bad}" cannot be half of a hostname'
		}
	}
}

fn test_ordinary_device_ids_are_accepted() {
	for ok in ['e5a16adf', 'E5A16ADF', '1A2B3C4D', 'dev-01', 'a', '12345678'] {
		s := parse_cansub_iface('cansub:${ok}/1') or {
			assert false, '"${ok}" is a perfectly good id: ${err}'
			return
		}
		assert s.id.to_lower() == ok.to_lower(), 'the id is kept, normalised'
	}
}

// A DNS label is 63 characters and `-usb` is appended, so the id itself has less room than that.
fn test_an_id_too_long_for_a_dns_label_is_refused() {
	assert cansub_id_ok('a'.repeat(59))
	assert !cansub_id_ok('a'.repeat(60))
	assert !cansub_id_ok('')
}

// The boolean half of the same tolerant reader — `/api/can/{ch}/phy` is where the controller's
// ACTUAL listen-only bit lives, and reconcile reads it back rather than trusting what it last set.
fn test_a_json_bool_is_found_however_it_is_spaced() {
	for body in ['{"listen_only":true}', '{"listen_only": true}', '{"listen_only" : true}',
		'{\n  "listen_only":\ttrue\n}'] {
		got := extract_json_bool(body, 'listen_only') or {
			assert false, 'did not parse: ${body}'
			return
		}
		assert got, body
	}
	assert extract_json_bool('{"listen_only":false}', 'listen_only')? == false
}

fn test_a_json_bool_that_is_not_one_is_no_answer() {
	assert extract_json_bool('{"listen_only":"true"}', 'listen_only') == none, 'a string is not a bool'
	assert extract_json_bool('{"listen_only":1}', 'listen_only') == none
	assert extract_json_bool('{"other":true}', 'listen_only') == none
	assert extract_json_bool('', 'listen_only') == none
}

// The real reply from a CANsub.4, so the field this depends on is pinned against the device rather
// than against my memory of it.
// THE DECISION LOGIC, WITHOUT A DEVICE. A CansubBus with `running = false` attempts no I/O, so the
// on-demand path can be driven against the process-wide fault table alone — which is where every
// review round on #223 landed, and which had no test (code-review high on #223).
fn test_a_standing_refusal_is_answered_from_memory_in_its_own_direction() {
	forget_silence_claims()
	iface := 'cansub:AAAA0001/1@500000'
	mut b := &CansubBus{
		iface: iface
		spec:  parse_cansub_iface(iface) or { panic(err) }
		rx:    chan CansubRecord{cap: 1}
	}
	lock b.stop {
		b.stop.running = false
	}
	// A fault in the wanted direction is returned without any attempt.
	apply_silence_explained(iface, true, fn (silent bool) int {
		return 500
	}, cansub_silence_reason) or {}
	if _ := b.reconcile_silence(true) {
		assert false, 'a standing refusal must be reported, not silently passed'
	} else {
		assert err.msg().contains('while the channel is open'), err.msg()
	}
	// A fault in the OTHER direction does not short-circuit: the attempt is made, and with the
	// bus not running it is "not attempted", which is an error and not a fault.
	forget_silence_claims()
	apply_silence_explained(iface, false, fn (silent bool) int {
		return 500
	}, cansub_silence_reason) or {}
	if _ := b.reconcile_silence(true) {
		assert false, 'not applied must never read as done'
	} else {
		assert err.msg().contains('not applied'), err.msg()
	}
	f := wire_silence_fault(iface) or {
		assert false, 'the other-direction fault must survive an unrelated attempt'
		return
	}
	assert !f.want
	// (close() forgetting the fault — ordered after `running` goes false — needs a bus whose
	// threads exist; a bus built with running = false to avoid I/O returns from close() at its
	// idempotence guard before it gets there. That ordering is the bench's to prove.)
	forget_silence_claims()
}

// AN UNTICK RESOLVES A REFUSED TICK. The device would not go silent; the row is unticked; the
// controller is now exactly where the row wants it, and the NOT SILENT fault must go with the
// request it was about (codex round 1 on #223).
fn test_a_request_in_the_other_direction_clears_a_standing_refusal() {
	forget_silence_claims()
	iface := 'cansub:AAAA0002/1@500000'
	apply_silence_explained(iface, true, fn (silent bool) int {
		return 500
	}, cansub_silence_reason) or {}
	assert wire_silence_fault(iface) != none
	// The controller is in normal mode and the row now asks for normal: the closure returns 0
	// (nothing to change) and the seam clears the fault.
	apply_silence_explained(iface, false, fn (silent bool) int {
		return 0
	}, cansub_silence_reason) or { assert false, err.msg() }
	assert wire_silence_fault(iface) == none
	forget_silence_claims()
}

// A 500 IS DECLARED; anything else is a fault. This is what lets silentcheck call a phase not
// applicable for the device's rule while still failing on a driver error.
fn test_only_the_live_channel_refusal_is_declared() {
	assert cansub_silence_reason(true, 500).declared
	assert !cansub_silence_reason(true, 400).declared
	assert !cansub_silence_reason(false, 503).declared
}

// A REFUSED MID-RUN PUT IS THE DEVICE'S RULE, NOT A DEFECT, and the message has to say what to do.
// Measured with curl on a CANsub.4 (02.04.00): the same PHY body is 200 with nothing on the channel
// and 500 while any client holds its WebSocket. The reconcile used to return from that 500 in
// silence, on every poll, for the life of the run.
fn test_a_refused_phy_put_names_the_live_channel_rule_and_the_remedy() {
	why := cansub_phy_refusal(500)
	assert why.contains('while the channel is open'), why
	assert why.contains('Stop and Start'), why
	other := cansub_phy_refusal(400)
	assert other.contains('400'), other
	assert !other.contains('while the channel is open'), 'only the live-channel 500 gets that reading'
}

fn test_the_devices_own_phy_reply_parses() {
	body := '{"listen_only":false,"auto_reset":true,"error_frames":true,"tx_ack_frames":true,"timing":{"brp":1,"seg1":127,"seg2":32,"sjw":4},"timing_data":{"brp":1,"seg1":31,"seg2":8,"sjw":4}}'
	assert extract_json_bool(body, 'listen_only')? == false
	assert extract_json_bool(body, 'auto_reset')? == true
}

// TWO SPELLINGS OF ONE WIRE, including the whitespace the parser ignores. A key that kept the
// spaces made `cansub:id / 1` and `cansub:id/1` two wires — so they evaded the rate and mode
// conflict checks and reached shared_open under different keys, which hands out two clients for a
// channel the vendor permits one on (codex round 17 on #204).
fn test_whitespace_in_an_address_does_not_make_a_second_wire() {
	a := destination_key('cansub:e5a16adf/1@500000')
	for spelling in ['cansub:e5a16adf / 1@500000', 'cansub: e5a16adf/1@500000',
		'cansub:E5A16ADF/01@500000'] {
		assert destination_key(spelling) == a, '${spelling} -> ${destination_key(spelling)}, want ${a}'
	}
}

// THE PROBE DOES NOT DIAL UNDER THE LOCK. The poll thread reads the device BEFORE it takes the
// wire lock and hands the answer in; a readback that failed reaches the closure as none, and the
// closure answers "not attempted" without touching the network. Decisive: the host here is one
// nothing answers on, and a dial to it would take net.dial_tcp's five seconds (codex round 3 on
// #223, where the dial under the lock was the OS connect timeout, unbounded).
fn test_a_probe_whose_readback_failed_does_not_dial_under_the_lock() {
	iface := 'cansub:AAAA0003/1@500000'
	mut b := &CansubBus{
		iface: iface
		host:  '10.255.255.1'
		spec:  parse_cansub_iface(iface) or { panic(err) }
		rx:    chan CansubRecord{cap: 1}
	}
	lock b.stop {
		b.stop.running = true
	}
	t0 := time.ticks()
	assert b.apply_phy_silence(true, true, none) == silence_not_attempted
	assert time.ticks() - t0 < 500, 'the closure reached the network: ${time.ticks() - t0} ms'
}

// A PROBE WHOSE POLICY MOVED DURING ITS READBACK ATTEMPTS NOTHING. The poll thread sampled
// "silent" and read the device outside the lock; the row was unticked meanwhile. Under the lock
// the policy says normal, so the stale pair must not be applied — and decisively not: the host
// here answers nothing, so a PUT would cost net.dial_tcp's five seconds (codex round 6 on #223).
fn test_a_probe_whose_policy_changed_meanwhile_attempts_nothing() {
	iface := 'cansub:AAAA0004/1@500000'
	clear_listen_only()
	mut b := &CansubBus{
		iface: iface
		host:  '10.255.255.1'
		spec:  parse_cansub_iface(iface) or { panic(err) }
		rx:    chan CansubRecord{cap: 1}
	}
	lock b.stop {
		b.stop.running = true
	}
	t0 := time.ticks()
	// The probe wanted silent and read the device as normal; the policy is now normal.
	assert b.apply_phy_silence(true, true, false) == silence_not_attempted
	assert time.ticks() - t0 < 500, 'the stale probe reached the network: ${time.ticks() - t0} ms'
}

// A PUT THAT COULD NOT BE DELIVERED AFTER A READBACK THAT DISPROVED THE RECORD clears the record
// and shows a fault that is NOT declared: the device was read, the controller is in the other
// mode, and nobody must take the recorded-state shortcut past that (codex round 8 on #223).
fn test_an_undelivered_put_after_a_readback_clears_the_record() {
	forget_silence_claims()
	iface := 'cansub:AAAA0005/1@500000'
	apply_silence_explained(iface, true, fn (silent bool) int {
		return 0
	}, cansub_silence_reason) or { assert false, err.msg() }
	assert recorded_silence(wire_key(iface))? == true
	apply_silence_probe(iface, true, fn (silent bool) int {
		return cansub_put_undelivered
	}, cansub_silence_reason) or {}
	assert recorded_silence(wire_key(iface)) == none, 'a disproved record must not stand'
	f := wire_silence_fault(iface) or {
		assert false, 'the undelivered PUT must be shown as a fault'
		return
	}
	assert !f.declared
	forget_silence_claims()
}
