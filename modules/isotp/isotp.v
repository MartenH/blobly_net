// isotp — ISO-TP (ISO 15765-2) transport: a message pipe that sends/receives
// whole PDUs (up to 4095 bytes), hiding CAN segmentation/flow-control. It is the
// byte carrier UDS (modules/uds) rides on. GUI-free.
//
// PLATFORM SPLIT (see CLAUDE.md → platform support): this file is platform-
// agnostic — it defines only the `Channel` interface and helpers. The actual
// backend is OS-specific and lives in an OS-suffixed file so it never compiles
// into the wrong target:
//   - Linux/WSL: `kernel_linux.v` — backed by the kernel CAN_ISOTP socket, which
//     does segmentation + flow control for us.
//   - Windows (later): a `*_windows.v` backend implementing the SAME `Channel`
//     interface in software (ISO-TP state machine) over a vendor CAN driver,
//     since Windows has no kernel ISO-TP.
// Callers depend only on `Channel` + `open()`, so swapping backends is invisible.
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

// request is the common send-then-await-one-reply pattern, backend-independent.
pub fn request(mut ch Channel, req []u8, timeout_ms int) ![]u8 {
	ch.send(req)!
	return ch.recv(timeout_ms)!
}
