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

// adapter_carries_fd reports whether the backend behind a project ADAPTER can put a CAN-FD frame
// on the wire. False for the two Windows vendor backends that refuse one, and for `doip`, which
// is not CAN at all.
//
// BY ADAPTER, not by interface string, because that is what the project stores and what the
// operator picks from a dropdown — and it is deliberately NOT platform-gated. On Linux a `pcan:`
// name opens as SocketCAN and would carry FD, but a project authored for a Windows bench is
// wrong about its own hardware whichever machine is reading it, and a warning that appeared only
// on the bench would be a warning nobody sees until they are standing at the bench.
//
// The list is the answer to "which backends did somebody implement FD for", so it lives beside
// the FD address parsing rather than in a front end: the GUI and the headless runner both ask,
// and a second copy of it would be the pair of them disagreeing about the same project.
pub fn adapter_carries_fd(adapter string) bool {
	return match adapter.trim_space().to_lower() {
		'pcan' { false } // refuses an FD frame rather than truncating it
		'doip' { false } // not a CAN bus
		else { true } // vector, socketcan/vcan, and the software buses
	}
}

// adapter_configures_bitrate reports whether an address for this adapter carries its nominal rate
// as an `@<bitrate>` suffix — whether OUR code sets the wire's speed when it opens the channel.
//
// ONE PREDICATE, because this was a literal `['pcan', 'kvaser', 'vector']` in five places in
// modules/project and a four-element version of the same list here in destination_key_for. When
// the CANsub backend landed, the one list that had been updated was this file's, so the transport
// layer knew `cansub:` addresses carry a rate and the project layer did not: a CANsub row composed
// its address without one, opened at the device's default, and the conflict checks that exist to
// stop two rows disagreeing about a wire's speed skipped it entirely. A list repeated six times is
// a list that will be updated five times.
//
// SocketCAN and the software buses answer false: `ip link` set the rate long before this process
// opened the interface, and `inproc:`/`udp:` have no rate at all.
pub fn adapter_configures_bitrate(adapter string) bool {
	return match adapter.trim_space().to_lower() {
		'pcan', 'kvaser', 'vector', 'cansub' { true }
		else { false }
	}
}

// adapter_configures_data_phase reports whether an address for this adapter carries the CAN-FD
// DATA rate — whether OUR code sets the payload phase when it opens the channel.
//
// NOT the same question as adapter_carries_fd, and the difference is exactly what a conflict
// check and an address composer each need. SocketCAN carries FD frames, but its data phase
// belongs to the interface and was set by `ip link` long before this process opened it: two rows
// disagreeing there is not something we configure, pin or can refuse. The vendor backends that
// take the rate IN THE ADDRESS are configuring it, so two rows asking for different ones is a
// contradiction only one of them can win.
//
// Kvaser joined Vector here when its FD support landed. It is a list of "who composes a data
// rate into an address", which is why it lives beside the address parsing and not in a front end.
pub fn adapter_configures_data_phase(adapter string) bool {
	return match adapter.trim_space().to_lower() {
		'vector', 'kvaser', 'cansub' { true }
		else { false }
	}
}

// vendor_split_fd_rate separates the rate token of a CAN-FD address: `<arb>/<data>`.
//
// THE DATA RATE IS THE FD FLAG. There is no separate `,fd` — one thing to say, so there is no way
// for the two to contradict each other, and no address that claims FD while naming a single rate
// the driver would then have to guess a payload phase for. `500000` is classic; `500000/2000000`
// is FD; `500000/500000` is FD with no bit-rate switch, which is a real configuration (64-byte
// payloads at the arbitration rate) and the reason the same-rate case has to be spellable.
//
// Returns (arb, data, is_fd). `data` is 0 when the address is classic, so a caller that ignores
// is_fd cannot silently configure a data phase.
pub fn vendor_split_fd_rate(tok string, default_rate int) !(int, int, bool) {
	t := tok.trim_space()
	if !t.contains('/') {
		return vendor_bitrate(t, default_rate)!, 0, false
	}
	parts := t.split('/')
	if parts.len > 2 {
		return error('"${t}" names more than two bitrates — a CAN-FD address is <arbitration>/<data>')
	}
	arb := vendor_bitrate(parts[0], default_rate)!
	data := vendor_bitrate(parts[1], default_rate)!
	// THE DATA PHASE CANNOT BE SLOWER. That is the whole point of the second rate — FD switches to
	// it to move the payload faster — and a controller asked for the reverse either refuses or
	// produces a bus nothing else on it can read. Caught here, where the numbers are still a
	// string the operator typed, rather than as a bare XL status from a channel that would not
	// configure.
	if data < arb {
		return error('CAN-FD data bitrate ${data} is slower than the arbitration bitrate ${arb} — the data phase is the fast one')
	}
	return arb, data, true
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
// `cancel` is asked between attempts and stops the wait when it answers true. A replay that is
// waiting out a full queue must notice Stop: the guard that ends a run is checked before this
// call, so without a way in, pressing Stop meant waiting out the whole retry budget while the
// worker's own taps were being closed underneath it.
pub fn send_waiting_for_room(mut b Bus, f CanFrame, attempts int, cancel fn () bool) ! {
	b.send(f) or {
		if !err.msg().starts_with(vector_busy_msg) {
			return err
		}
		mut last := err
		for _ in 0 .. attempts {
			if cancel() {
				return last
			}
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
