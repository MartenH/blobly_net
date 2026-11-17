// isotp — ISO-TP (ISO 15765-2) transport: a message pipe that sends/receives
// whole PDUs (up to 65535 bytes), hiding CAN segmentation/flow-control. It is the
// byte carrier UDS (blobly/uds) rides on. GUI-free.
//
// PLATFORM SPLIT (see CLAUDE.md → platform support): this file is platform-
// agnostic — the `Channel` interface, helpers, and `open()`. Two backends
// implement the interface:
//   - `kernel_linux.v` — the kernel CAN_ISOTP socket, which does segmentation
//     + flow control for us. Linux/WSL only (the suffix gates it).
//   - `software.v` — the ISO-TP state machine in V over any `transport.Bus`,
//     so it runs wherever a bus opens: vendor drivers on Windows, the in-process
//     and UDP buses everywhere.
// `open()` picks: the kernel where it exists, software elsewhere. Callers depend
// only on `Channel` + `open()`, so the platform is invisible to them — which was
// the promise here from the start, kept by nothing until #220: `open` lived in the
// Linux file, and the two smoke tools that took the promise at its word had not
// compiled on Windows since the rename that put it there.
module isotp

import blobly.transport

// max_pdu is the longest message a channel sends or receives: past ff12_max its First Frame gives
// the 32-bit length (ISO 15765-2:2016), bounded at 64 KiB as a DoIP diagnostic message is. A First
// Frame declaring more is answered with Flow Control OVERFLOW. The kernel socket carries what its
// own max_pdu_size allows (8300 bytes by default).
pub const max_pdu = 65535

// Channel is a platform-agnostic ISO-TP message pipe. Each OS backend provides a
// concrete implementation + an `open()` that returns one.
pub interface Channel {
	iface string
	tx_id u32
	rx_id u32
mut:
	send(data []u8) !
	recv(timeout_ms int) ![]u8
	close()
	// diagnostics is what the carrier underneath counted that no PDU carried -- the software
	// channel's bus answers (#213); the kernel socket and DoIP have nothing to say. Here so a
	// UDS connection a script opened can report at the end of a run like a bus it opened can.
	diagnostics() transport.BusDiagnostics
}

// std_id_max is the largest 11-bit CAN identifier.
pub const std_id_max = u32(0x7FF)

// ext_id_max is the largest 29-bit CAN identifier.
pub const ext_id_max = u32(0x1FFFFFFF)

// pair_ext is whether a connection's request and response ids are 29-bit: where `declared` says so,
// or where either id is past 0x7FF, which no 11-bit id can be. The ONE spelling of that rule —
// sysview's node formats, udsconn's opener, the GUI's targets all ask it.
pub fn pair_ext(declared bool, a u32, b u32) bool {
	return declared || a > std_id_max || b > std_id_max
}

// open returns an ISO-TP channel on `iface`, transmitting on `tx_id` and receiving on `rx_id`;
// `extended` for 29-bit identifiers. The kernel socket on Linux, the software state machine
// everywhere else — see the platform note at the top. A caller that wants the software channel
// ON Linux too (a bus the kernel has no socket for, or one it needs to see the frames of) asks for
// it by name: open_software / on_bus.
// check_ids refuses an id that does not fit its declared width, ONCE, for every opener: the
// kernel channel masked an oversized id and bound to a different endpoint, the software one kept
// it and waited on an id no frame can carry (codex round 17 on #225) — and a check only in open()
// left the named openers unchecked (round 20).
fn check_ids(iface string, tx_id u32, rx_id u32, extended bool) ! {
	limit := if extended { u32(0x1FFF_FFFF) } else { u32(0x7FF) }
	if tx_id > limit || rx_id > limit {
		return error('isotp open ${iface}: id 0x${(if tx_id > limit { tx_id } else { rx_id }):X} does not fit ${if extended { '29' } else { '11' }} bits')
	}
}

pub fn open(iface string, tx_id u32, rx_id u32, extended bool) !Channel {
	check_ids(iface, tx_id, rx_id, extended)!
	$if linux {
		return open_kernel(iface, tx_id, rx_id, extended)
	} $else {
		soft := open_software(iface, tx_id, rx_id, extended)!
		return soft
	}
}

// request is the common send-then-await-one-reply pattern, backend-independent.
pub fn request(mut ch Channel, req []u8, timeout_ms int) ![]u8 {
	ch.send(req)!
	return ch.recv(timeout_ms)!
}
