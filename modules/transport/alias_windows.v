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
	reach, key := physical_wire(adapter, iface)
	if reach != .resolved {
		return none
	}
	return key
}

// physical_wire is the same question with the THREE answers it actually has (#194).
//
// `physical_wire_key` folds two of them into `none`, and the caller reads `none` as "no opinion" —
// correct for one of them and dangerous for the other:
//
//   - `nothing`    the driver ANSWERED and this application channel points at no hardware. It
//                  cannot be sharing a transceiver with anything, so skipping it is right.
//   - `unreadable` the driver would not say. The row may well be aliased onto another row's
//                  physical channel and nothing here can tell — so treating it like `nothing`
//                  lets exactly the alias #167 exists to catch through the check unremarked.
//
// The alias check cannot fail CLOSED on `unreadable`: a bench with the XL library mid-upgrade
// would have every project refused for a question nobody could answer. So it reports instead —
// see project.alias_unreadable_warnings.
pub fn physical_wire(adapter string, iface string) (WireReach, string) {
	if adapter.to_lower() != 'vector' {
		return WireReach.nothing, ''
	}
	// Through the backend's own resolver, so every spelling this app accepts — `vector:1`,
	// `vector:ch1`, `vector:app01`, with or without a rate or a mode — arrives as one channel
	// number, exactly as it does at open. A second reading of the address here could disagree
	// with the one that opens the port, which is the drift vector_names.v exists to prevent.
	body := iface.trim_space().all_after_first(':')
	spec := parse_vector_spec(body) or { return WireReach.nothing, '' }
	// THE FOUR-STATE ANSWER, not vector_assignment's two. `absent` is the driver saying it has no
	// such channel, which reaches nothing; `unreadable` is silence and must stay separate. Reading
	// them through the two-state API is what made this indistinguishable in the first place.
	match vector_app_slot(spec.channel) {
		.unreadable {
			return WireReach.unreadable, ''
		}
		.absent {
			// NOT `nothing`, though it looks like it should be. `absent` rests on XL's GENERIC
			// error, so a channel that fails to read twice is indistinguishable from one that is
			// genuinely unregistered — and if the truth was the former, the row may be pointing at
			// hardware another row also claims. Calling that "reaches nothing" skips it silently
			// and lets the #167 alias through, which is precisely what this function was changed to
			// prevent (codex #199 r1).
			//
			// The same ambiguity makes creating a channel the operator's decision in the Discover
			// dialog. It is the one honest reading in both places: only `empty` is the driver
			// POSITIVELY describing a registered channel with nothing behind it.
			return WireReach.unreadable, ''
		}
		.empty {
			// Registered and pointing at nothing, said positively. No hardware is behind it, and it
			// fails at open with a message of its own (-1000), which is the right place for that.
			return WireReach.nothing, ''
		}
		.taken {}
	}
	hw, assigned := vector_assignment(spec.channel) or {
		// It said `taken` a moment ago and will not say what it points at now.
		return WireReach.unreadable, ''
	}
	if !assigned {
		return WireReach.nothing, ''
	}
	// The triple Vector Hardware Manager assigns, which is what xlGetChannelMask turns into the
	// mask the driver keys its configuration on. Two application channels with the same triple
	// are the same transceiver.
	return WireReach.resolved, 'vector-hw:${hw.hw_type}:${hw.hw_index}:${hw.hw_channel}'
}
