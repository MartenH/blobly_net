// The vendor interface spec, for every backend that has one.
//
// NOT in any one backend's file, and not named after one, because the rules below have now been
// got wrong once per backend: `.int()` accepting a numeric prefix was fixed in the project
// loader, then in Vector, then in PCAN and Kvaser; "at most one bitrate" was fixed in Vector and
// left in the other two. Each fix was correct and none of them was the last one, because the
// rule kept living next to a single caller. It lives here now and all three call it.
module transport

import time

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

// send_waiting_for_room offers a frame, waiting out a full vendor transmit queue.
//
// A saturated bus is the slowest thing in the system and says so by refusing; a replay of a busy
// capture reaches that constantly, and treating it as a failure puts holes in the replay exactly
// where the recording was densest. Waiting is the whole answer.
//
// ONLY "still busy" earns another attempt. A retry that fails for a NEW reason — the adapter
// unplugged, the port broken — is returned as itself: catching every error and going round
// again reported a disconnected adapter as ordinary back-pressure, after several hundred
// milliseconds of talking to nothing. That mistake was made independently in both callers,
// which is why the loop lives here now instead of in each of them.
pub fn send_waiting_for_room(mut b Bus, f CanFrame, attempts int) ! {
	b.send(f) or {
		if !err.msg().starts_with(vector_busy_msg) {
			return err
		}
		mut last := err
		for _ in 0 .. attempts {
			time.sleep(time.millisecond)
			b.send(f) or {
				last = err
				if err.msg().starts_with(vector_busy_msg) {
					continue
				}
				return err
			}
			return
		}
		return last
	}
}
