module transport

// The identity predicates are answered in place now; these pin them to the spellings they
// replaced, over the shapes an interface string takes: as a project writes it, upper-cased,
// with the whitespace trim_space strips on either side, empty, and shorter than the prefix.
const iface_shapes = ['vector:1', 'Vector:1', ' vector:1', '\tKVASER:0\n', 'kvaser:0', 'cansub:x/1',
	'CANSUB:x/1', ' cansub:x', 'pcan:PCAN_USBBUS1@500000', 'PCAN:x', 'inproc:CAN1', 'inproc:bench@A',
	'vcan0', 'udp:239.0.0.1:5000', '', 'v', 'vector', 'vector:', '  ', 'x vector:1']

fn old_vendor_iface(iface string) bool {
	if iface.to_lower().starts_with('cansub:') {
		return true
	}
	$if windows {
		i := iface.to_lower()
		return i.starts_with('pcan:') || i.starts_with('kvaser:') || i.starts_with('vector:')
	} $else {
		return false
	}
}

fn old_echoes_own_sends(iface string) bool {
	if iface.trim_space().to_lower().starts_with('vector:') {
		return true
	}
	if iface.trim_space().to_lower().starts_with('kvaser:') {
		return true
	}
	if iface.trim_space().to_lower().starts_with('cansub:') {
		return true
	}
	return !old_vendor_iface(iface)
}

fn test_vendor_iface_answers_as_the_lowercased_prefix_did() {
	for s in iface_shapes {
		assert vendor_iface(s) == old_vendor_iface(s), 'vendor_iface(${s.str()})'
		assert vendor_iface(trimmed(s)) == old_vendor_iface(s.trim_space()), 'vendor_iface(trimmed(${s.str()}))'
	}
}

fn test_echoes_own_sends_answers_as_the_trimmed_lowercased_prefix_did() {
	for s in iface_shapes {
		assert echoes_own_sends(s) == old_echoes_own_sends(s), 'echoes_own_sends(${s.str()})'
	}
}

fn test_lead_space_is_where_trim_space_starts() {
	for s in iface_shapes {
		t := s.trim_space()
		if t.len > 0 {
			assert s[lead_space(s)..].starts_with(t), s.str()
		} else {
			assert lead_space(s) == s.len, s.str()
		}
	}
}

fn test_trimmed_returns_the_input_itself_when_nothing_is_trimmed() {
	for s in iface_shapes {
		t := trimmed(s)
		assert t == s.trim_space(), s.str()
		if t.len == s.len {
			assert t.str == s.str, 'a copy of ${s.str()} where none was needed'
		}
	}
}

fn test_wire_key_and_destination_key_unchanged() {
	for s in iface_shapes {
		// the software-bus answer is the canonical name untrimmed; the vendor answer is the
		// destination without its rate -- both as before, now without the copies
		if !vendor_iface(s.trim_space()) {
			assert wire_key(s) == canonical_iface(s), s.str()
		} else {
			assert wire_key(s) == vendor_destination_key(s).all_before('@'), s.str()
		}
		assert destination_key(s) == destination_key(s.trim_space()), s.str()
	}
}
