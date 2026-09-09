module project

// The shape #97 is about: two configured channels on ONE wire. An interface picks the wire; only
// a name picks the owner.
fn shared_wire() []Channel {
	return [
		Channel{
			name: 'Powertrain'
			iface: 'inproc:CAN1'
		},
		Channel{
			name: 'Chassis'
			iface: 'inproc:CAN1'
		},
		Channel{
			name: 'Body'
			iface: 'inproc:CAN2'
		},
	]
}

fn test_empty_bus_is_the_generators_own_channel() {
	chs := shared_wire()
	r := resolve_sender_bus('', chs[1], chs)
	assert r.kind == .own
	assert r.chan == 'Chassis'
	assert r.iface == 'inproc:CAN1'
	assert r.note == ''
}

// THE FIX. Under the old rule this value would have been handed to the transport as a device
// name; under the new one it is the second channel on the shared wire, which is the selection
// that used to revert on save/reload.
fn test_a_name_picks_the_channel_an_interface_cannot() {
	chs := shared_wire()
	r := resolve_sender_bus('Chassis', chs[0], chs)
	assert r.kind == .named
	assert r.chan == 'Chassis'
	assert r.iface == 'inproc:CAN1'
	assert r.note == ''
	// …and its sibling on the SAME wire resolves to the other owner. This is the assertion the
	// interface form cannot satisfy at all: both would be 'inproc:CAN1' and indistinguishable.
	r2 := resolve_sender_bus('Powertrain', chs[1], chs)
	assert r2.chan == 'Powertrain'
	assert r2.iface == r.iface
}

// The migration: every project written to the old documentation still resolves, and to the right
// owner when the wire has exactly one channel.
fn test_an_interface_naming_one_channel_still_resolves() {
	chs := shared_wire()
	r := resolve_sender_bus('inproc:CAN2', chs[0], chs)
	assert r.kind == .iface
	assert r.chan == 'Body'
	assert r.iface == 'inproc:CAN2'
	assert r.note == '', 'a file written to the old documentation is not a problem to announce'
}

// The old form on a SHARED wire is the ambiguity #97 reports. It still transmits — that is
// today's behaviour and removing it would break working projects — but it says so instead of
// silently attributing the frames to whichever channel came first.
fn test_an_interface_two_channels_share_is_ambiguous_but_still_transmits() {
	chs := shared_wire()
	r := resolve_sender_bus('inproc:CAN1', chs[2], chs)
	assert r.kind == .ambiguous
	assert r.iface == 'inproc:CAN1', 'the wire is not in doubt, only the owner'
	assert r.chan == '', 'no single channel owns it, and guessing is what #97 is about'
	assert r.note.contains('Powertrain'), r.note
	assert r.note.contains('Chassis'), r.note
}

// A name is not an identity either — nothing enforces unique channel names — so the same verdict
// has to cover a duplicated NAME. It shares the wire, so it can still send.
fn test_a_duplicated_channel_name_is_ambiguous_on_a_shared_wire() {
	chs := [
		Channel{
			name: 'CAN'
			iface: 'inproc:X'
		},
		Channel{
			name: 'CAN'
			iface: 'inproc:X'
		},
	]
	r := resolve_sender_bus('CAN', chs[0], chs)
	assert r.kind == .ambiguous
	assert r.iface == 'inproc:X'
	assert r.chan == ''
	assert r.note.contains('2 channels'), r.note
}

// …and when the duplicates are on DIFFERENT wires there is nothing to open, which is a stronger
// statement than "no owner" and must not be reported as if the send still went somewhere.
fn test_a_duplicated_channel_name_on_different_wires_has_nowhere_to_send() {
	chs := [
		Channel{
			name: 'CAN'
			iface: 'inproc:X'
		},
		Channel{
			name: 'CAN'
			iface: 'inproc:Y'
		},
	]
	r := resolve_sender_bus('CAN', chs[0], chs)
	assert r.kind == .ambiguous
	assert r.iface == '', 'two wires, no way to choose'
	assert r.note.contains('different interfaces'), r.note
}

// The capability the name form cannot express, and the reason an interface stays legal: a wire
// that is not a configured channel, carrying its own rate. Start opens a tap for it on purpose.
fn test_an_interface_no_channel_has_is_a_bare_wire_not_an_error() {
	chs := shared_wire()
	r := resolve_sender_bus('pcan:PCAN_USBBUS1@250000', chs[0], chs)
	assert r.kind == .bare
	assert r.iface == 'pcan:PCAN_USBBUS1@250000', 'passed through verbatim, rate and all'
	assert r.chan == ''
	assert r.note == '', 'deliberate, not a misconfiguration'
}

// The tie-break, stated as a test because it is the one case where the two forms could collide:
// a channel NAMED like a wire. The name wins, because that is what the key means.
fn test_a_name_wins_over_an_interface_of_the_same_spelling() {
	chs := [
		Channel{
			name: 'vcan0'
			iface: 'inproc:CAN9'
		},
		Channel{
			name: 'Other'
			iface: 'vcan0'
		},
	]
	r := resolve_sender_bus('vcan0', chs[1], chs)
	assert r.kind == .named
	assert r.chan == 'vcan0'
	assert r.iface == 'inproc:CAN9', 'the channel named vcan0, not the wire spelled vcan0'
}

// v4 asks whether an OLDER build would send the generator somewhere ELSE — not which form the
// value happens to be written in.
fn test_needs_v4_is_about_a_changed_destination_not_a_changed_spelling() {
	chs := shared_wire()
	assert sender_bus_needs_v4('Chassis', chs[0], chs), 'an old build opens a device called Chassis'
	assert !sender_bus_needs_v4('inproc:CAN1', chs[0], chs), 'the legacy form opens the same wire'
	assert !sender_bus_needs_v4('', chs[0], chs), 'an empty bus is the own channel either way'
	assert !sender_bus_needs_v4('pcan:PCAN_USBBUS1@250000', chs[0], chs), 'a bare wire is unchanged'
	// Two rows answering to one name on DIFFERENT wires: this build sends nowhere, an older one
	// opens a device by that name. Different behaviour, so the file must say so.
	dup := [
		Channel{
			name: 'CAN'
			iface: 'inproc:X'
		},
		Channel{
			name: 'CAN'
			iface: 'inproc:Y'
		},
	]
	assert sender_bus_needs_v4('CAN', dup[0], dup)
}

// THE OVERLAP THE WHICH-FORM TEST GOT WRONG. For socketcan a row's name defaults to its address
// and compose_iface returns that address bare, so a channel NAMED `vcan1` sits on the INTERFACE
// `vcan1` and the legacy `bus: vcan1` is both forms at once. It resolves to the same wire either
// way, so it is not a v4 file — labelling it one makes every older build warn about a project
// whose meaning has not changed.
fn test_a_row_named_after_its_own_address_is_not_a_v4_file() {
	chs := [
		Channel{
			name: 'vcan0'
			iface: 'vcan0'
		},
		Channel{
			name: 'vcan1'
			iface: 'vcan1'
		},
	]
	r := resolve_sender_bus('vcan1', chs[0], chs)
	assert r.kind == .named, 'the name is still what answers first'
	assert r.iface == 'vcan1', 'and it is the same wire the old rule would have opened'
	assert !sender_bus_needs_v4('vcan1', chs[0], chs)
	mut p := Project{
		channels: chs
	}
	p.channels[0].senders = [
		Sender{
			name: 'to vcan1'
			bus: 'vcan1'
		},
	]
	assert version_for(p) == 2
}

fn test_warnings_name_only_what_cannot_be_settled() {
	mut chs := shared_wire()
	// one of each: own, a name, the legacy interface form, a bare wire — none of them a warning
	chs[0].senders = [
		Sender{
			name: 'own'
			bus: ''
		},
		Sender{
			name: 'byname'
			bus: 'Chassis'
		},
		Sender{
			name: 'legacy'
			bus: 'inproc:CAN2'
		},
		Sender{
			name: 'bare'
			bus: 'pcan:PCAN_USBBUS1@250000'
		},
	]
	assert sender_bus_warnings(chs).len == 0, '${sender_bus_warnings(chs)}'
	// and the one that cannot be settled
	chs[2].senders = [
		Sender{
			name: 'shared'
			bus: 'inproc:CAN1'
		},
	]
	w := sender_bus_warnings(chs)
	assert w.len == 1, '${w}'
	assert w[0].starts_with('generator shared:'), w[0]
	assert w[0].contains('inproc:CAN1'), w[0]
}

// The GUI attributes an unowned generator to EVERY channel on the wire it targets — it has to,
// or its other warnings go unsaid — so the same generator arrives here once per sharer. One
// warning, not one per row.
fn test_an_unowned_generator_warns_once_not_once_per_sharer() {
	mut chs := shared_wire()
	g := Sender{
		name: 'shared'
		bus: 'inproc:CAN1'
	}
	chs[0].senders = [g]
	chs[1].senders = [g]
	w := sender_bus_warnings(chs)
	assert w.len == 1, '${w}'
}

// A project that uses the NAME form must say so in `version:`: a build released before #97 reads
// `bus:` as an interface and hands the name to the transport as a device name, which fails to
// open. Everything else keeps declaring the version it declared, so ordinary projects stay
// openable by older builds with no note.
fn test_version_for_named_bus() {
	mut p := Project{
		channels: shared_wire()
	}
	p.channels[0].senders = [
		Sender{
			name: 'legacy'
			bus: 'inproc:CAN2'
		},
	]
	assert version_for(p) == 2, 'the interface form is what every older build already expects'
	p.channels[0].senders = [
		Sender{
			name: 'bare'
			bus: 'pcan:PCAN_USBBUS1@250000'
		},
	]
	assert version_for(p) == 2, 'a bare wire is an interface too'
	p.channels[0].senders = [
		Sender{
			name: 'byname'
			bus: 'Chassis'
		},
	]
	assert version_for(p) == 4
}

// THE REPORTED SYMPTOM, end to end: a generator owned by the SECOND channel of a shared wire
// survives a save and a reload. Under the old rule the picker had nothing to store — that
// channel's interface equals the first's, so `bus:` came out empty — and the reload restored
// ownership from the first channel, silently reverting the selection.
//
// Through the real writer and the real parser, not a struct copy: the value has to survive being
// spelled into YAML and read back, which is where a format decision actually lives.
fn test_a_generator_on_the_second_channel_of_a_shared_wire_survives_a_round_trip() {
	mut orig := Project{
		name: 'shared'
		channels: shared_wire()
	}
	// nested under the FIRST channel of the wire, but owned by the SECOND
	orig.channels[0].senders = [
		Sender{
			name: 'Chassis torque'
			id: 0x100
			bus: 'Chassis'
			trigger: 'cyclic'
			cycle_ms: 100
		},
	]
	text := orig.to_yaml()
	assert text.contains('bus: Chassis'), text
	rp := parse(text) or {
		assert false, err.msg()
		return
	}
	assert rp.version == 4, 'the name form is not readable by a build released before #97'
	assert rp.channels[0].senders.len == 1
	assert rp.channels[1].senders.len == 0, 'it belongs to the channel it is nested under'
	g := rp.channels[0].senders[0]
	assert g.bus == 'Chassis'
	// …and it still resolves to the second channel, which is the whole point.
	r := resolve_sender_bus(g.bus, rp.channels[0], rp.channels)
	assert r.kind == .named
	assert r.chan == 'Chassis', 'the selection reverted to the first channel before #97'
	assert r.iface == 'inproc:CAN1'
}

// And the migration in the same shape: a file written to the OLD documentation round-trips
// unchanged and keeps declaring the version it always did.
fn test_the_interface_form_round_trips_and_stays_v2() {
	mut orig := Project{
		name: 'legacy'
		channels: shared_wire()
	}
	orig.channels[0].senders = [
		Sender{
			name: 'to Body'
			id: 0x200
			bus: 'inproc:CAN2'
		},
	]
	rp := parse(orig.to_yaml()) or {
		assert false, err.msg()
		return
	}
	assert rp.version == 2, 'an older build reads this exactly as it always has'
	g := rp.channels[0].senders[0]
	assert g.bus == 'inproc:CAN2'
	r := resolve_sender_bus(g.bus, rp.channels[0], rp.channels)
	assert r.kind == .iface
	assert r.chan == 'Body'
}

// ==== the WRITER's side: what spells a target =========================================
fn test_bus_value_is_empty_for_the_generators_own_channel() {
	chs := shared_wire()
	v := sender_bus_value(chs[1], chs[1], chs) or {
		assert false, 'own channel must be expressible'
		return
	}
	assert v == ''
}

fn test_bus_value_is_the_name_where_a_name_exists() {
	chs := shared_wire()
	v := sender_bus_value(chs[1], chs[0], chs) or {
		assert false, 'a named channel is always expressible'
		return
	}
	assert v == 'Chassis'
	// …and it round-trips: the value written resolves back to the row that was picked.
	r := resolve_sender_bus(v, chs[0], chs)
	assert r.chan == 'Chassis'
	assert r.iface == chs[1].iface
}

// An unnamed row is addressed by its interface, which is what the picker relies on.
fn test_bus_value_falls_back_to_the_interface_for_an_unnamed_row() {
	chs := [
		Channel{
			name: 'Powertrain'
			iface: 'inproc:CAN1'
		},
		Channel{
			name: ''
			iface: 'inproc:CAN2'
		},
	]
	v := sender_bus_value(chs[1], chs[0], chs) or {
		assert false, 'an unnamed row on its own wire is expressible'
		return
	}
	assert v == 'inproc:CAN2'
}

// THE COLLISION THE FALLBACK GOT WRONG: the unnamed row's interface is ANOTHER channel's name, so
// writing it would resolve name-first to that other channel, on another wire. There is no
// spelling for this row, and saying so is the only correct answer.
fn test_bus_value_refuses_an_unnamed_row_whose_interface_is_another_channels_name() {
	chs := [
		Channel{
			name: 'inproc:CAN2' // a channel NAMED like the other one's wire
			iface: 'inproc:CAN9'
		},
		Channel{
			name: ''
			iface: 'inproc:CAN2'
		},
	]
	// the value the old fallback would have written goes somewhere else entirely
	wrong := resolve_sender_bus('inproc:CAN2', chs[0], chs)
	assert wrong.iface == 'inproc:CAN9', 'name-first sends it to the namesake channel'
	if v := sender_bus_value(chs[1], chs[0], chs) {
		assert false, 'expected no spelling, got "${v}"'
	}
}

// Every value this returns must resolve back to the row it was asked about — the property the
// picker relies on, asserted over every ordered pair of a project that mixes the difficult cases.
fn test_every_spelling_round_trips() {
	chs := [
		Channel{
			name: 'Powertrain'
			iface: 'inproc:CAN1'
		},
		Channel{
			name: 'Chassis'
			iface: 'inproc:CAN1'
		},
		Channel{
			name: 'vcan0'
			iface: 'vcan0'
		},
		Channel{
			name: ''
			iface: 'inproc:CAN2'
		},
	]
	for own in chs {
		for target in chs {
			v := sender_bus_value(target, own, chs) or { continue }
			r := resolve_sender_bus(v, own, chs)
			assert r.iface == target.iface, 'spelling "${v}" for ${target.name}/${target.iface} opened ${r.iface}'
			assert r.chan == target.name || r.chan == '', 'spelling "${v}" named ${r.chan}'
		}
	}
}
