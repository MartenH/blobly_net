// The vendor interface spec, for every backend that has one.
//
// NOT in any one backend's file, and not named after one, because the rules below have now been
// got wrong once per backend: `.int()` accepting a numeric prefix was fixed in the project
// loader, then in Vector, then in PCAN and Kvaser; "at most one bitrate" was fixed in Vector and
// left in the other two. Each fix was correct and none of them was the last one, because the
// rule kept living next to a single caller. It lives here now and all three call it.
module transport

// vendor_bitrate parses the `@<rate>` a vendor interface carries, refusing a token that is only
// PARTLY a number.
//
// Shared by all three vendor backends, because V's `.int()` takes a numeric prefix and every one
// of them used it: `@250000garbage` opened the hardware at 250 kbit/s while the project model,
// which validates strictly, went on believing the default. The two disagreed about a live bus,
// and only one of them was driving it.
pub fn vendor_bitrate(tok string, default_rate int) !int {
	t := tok.trim_space()
	if t == '' {
		return error('empty bitrate after "@"')
	}
	for c in t {
		if !c.is_digit() {
			return error('"${t}" is not a bitrate — digits only, in bits per second')
		}
	}
	n := t.int()
	if n <= 0 {
		return error('bitrate ${n} is not a rate')
	}
	return n
}

// vendor_split_rate separates `<channel>[@<bitrate>]`, applying both rules: at most one rate,
// and that rate a whole number.
//
// TWO RATES is not a preference for the first. It is reachable without trying: a v2 address that
// already carries a legacy `@250000` gets the channel's own bitrate appended by
// iface_with_bitrate, and the hardware then runs at 250 kbit/s while the project reports 500 —
// two answers about a live bus, one of them driving it.
pub fn vendor_split_rate(spec string, default_rate int) !(string, int) {
	parts := spec.split('@')
	if parts.len > 2 {
		return error('"${spec}" has more than one bitrate — the rate belongs in the channel\'s bitrate field, not in its address')
	}
	if parts.len > 1 {
		return parts[0], vendor_bitrate(parts[1], default_rate)!
	}
	return parts[0], default_rate
}
