module transport

// physical_wire_key — the PHYSICAL channel an address reaches, where this machine can tell.
//
// The Windows half, and the one that can answer. See alias_linux.v for why the other returns
// none, and issue #167 for what this exists to catch: `vector:1` and `vector:2` are two
// application channels and two wires to every part of this app, and Vector Hardware Manager will
// happily assign both to ONE physical VN channel. To the driver they are then one channel — the
// same mask, the same entry in the shim's configuration table — while destination_key keeps them
// apart, so the rate check, the listen-only check, the one-monitor rule, the transmit lock and
// the pin guard all reason about half a wire each.
//
// ONLY VECTOR. PCAN and Kvaser address hardware directly: `pcan:PCAN_USBBUS1` names a channel,
// not an indirection to one, so there is no second name for it to hide behind. The Vector layer
// of application channels is what creates the alias, and it is the only one asked about here.
pub fn physical_wire_key(adapter string, iface string) ?string {
	if adapter.to_lower() != 'vector' {
		return none
	}
	// Through the backend's own resolver, so every spelling this app accepts — `vector:1`,
	// `vector:ch1`, `vector:app01`, with or without a rate or a mode — arrives as one channel
	// number, exactly as it does at open. A second reading of the address here could disagree
	// with the one that opens the port, which is the drift vector_names.v exists to prevent.
	body := iface.trim_space().all_after_first(':')
	spec := parse_vector_spec(body) or { return none }
	hw, assigned := vector_assignment(spec.channel) or {
		// NO DRIVER, NO OPINION. A bench without the XL library, or with it mid-upgrade, must not
		// have a project refused on the strength of a question nobody could answer. The caller
		// treats none as "cannot say", never as "they are different".
		return none
	}
	if !assigned {
		// An application channel with no hardware behind it reaches nothing, so it cannot be
		// sharing anything. It fails at open with a message of its own (-1000), which is the
		// right place for it.
		return none
	}
	// The triple Vector Hardware Manager assigns, which is what xlGetChannelMask turns into the
	// mask the driver keys its configuration on. Two application channels with the same triple
	// are the same transceiver.
	return 'vector-hw:${hw.hw_type}:${hw.hw_index}:${hw.hw_channel}'
}
