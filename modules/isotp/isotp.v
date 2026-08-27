// isotp — ISO-TP (ISO 15765-2) transport: a message pipe that sends/receives
// whole PDUs (up to 4095 bytes), hiding CAN segmentation/flow-control. It is the
// byte carrier UDS (modules/uds) rides on. GUI-free.
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

// max_pdu is the ISO-TP maximum service data unit (classic addressing).
pub const max_pdu = 4095

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
}

// open returns an ISO-TP channel on `iface`, transmitting on `tx_id` and receiving on `rx_id`;
// `extended` for 29-bit identifiers. The kernel socket on Linux, the software state machine
// everywhere else — see the platform note at the top. A caller that wants the software channel
// ON Linux too (a bus the kernel has no socket for, or one it needs to see the frames of) asks for
// it by name: open_software / on_bus.
pub fn open(iface string, tx_id u32, rx_id u32, extended bool) !Channel {
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
