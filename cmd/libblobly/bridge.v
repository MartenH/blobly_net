// The CAN bridge into WSL (bb.h's "The CAN bridge" block): the distributions, starting and
// stopping a bridge, its state and its channels, over blobly.transport's bridge registry — the
// calls the GUI's Discover dialog makes.
module main

import blobly.transport

// how long bb_bridge_stop waits for the bridge's session to end once its connection is shut down
const bridge_stop_ms = 2000

// bridge_name is the host's distribution name, refused when absent or empty.
fn bridge_name(distro &char) ?string {
	if isnil(distro) {
		return none
	}
	name := unsafe { cstring_to_vstring(distro) }
	return if name == '' { none } else { name }
}

@[export: 'bb_wsl_distros']
pub fn bb_wsl_distros(buf &char, cap i32) i32 {
	return put(transport.wsl_distros().join('\n'), buf, cap)
}

@[export: 'bb_bridge_program']
pub fn bb_bridge_program(buf &char, cap i32) i32 {
	return put(transport.bridge_program() or { '' }, buf, cap)
}

@[export: 'bb_bridge_start']
pub fn bb_bridge_start(distro &char) i32 {
	name := bridge_name(distro) or { return fail(bb_err, 'bridge_start: no distribution') }
	transport.bridge_start(name) or { return fail(bb_err, err.msg()) }
	return ok()
}

@[export: 'bb_bridge_state']
pub fn bb_bridge_state(distro &char, state &i32, why &char, cap i32) i32 {
	name := bridge_name(distro) or { return fail(bb_err, 'bridge_state: no distribution') }
	if isnil(state) {
		return fail(bb_err, 'bridge_state: nowhere to put the state')
	}
	st, reason := transport.bridge_state(name)
	unsafe {
		*state = i32(match st {
			.idle { C.BB_BRIDGE_IDLE }
			.starting { C.BB_BRIDGE_STARTING }
			.connected { C.BB_BRIDGE_CONNECTED }
			.failed { C.BB_BRIDGE_FAILED }
		})
	}
	return put(reason, why, cap)
}

@[export: 'bb_bridge_rows']
pub fn bb_bridge_rows(distro &char, buf &char, cap i32) i32 {
	name := bridge_name(distro) or { return fail(bb_err, 'bridge_rows: no distribution') }
	rows := transport.bridge_channels(name).map('bridge:${name}/${it}')
	return put(rows.join('\n'), buf, cap)
}

@[export: 'bb_bridge_stop']
pub fn bb_bridge_stop(distro &char) i32 {
	name := bridge_name(distro) or { return fail(bb_err, 'bridge_stop: no distribution') }
	// a run's bridge rows are its topology, as the GUI's Disconnect is offered only while stopped
	if !isnil(bb_run) {
		return fail(bb_err_state, 'a run is active; stop it before stopping a bridge its channels may use')
	}
	st, _ := transport.bridge_state(name)
	if st != .connected {
		return fail(bb_err_state, 'no bridge named "${name}" is connected')
	}
	// cut, but its session did not end within the wait
	transport.bridge_stop(name, bridge_stop_ms) or { return fail(i32(C.BB_ERR_TIMEOUT), err.msg()) }
	return ok()
}
