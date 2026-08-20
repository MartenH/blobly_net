// PCAN channel NAMES, deliberately not in pcan_windows.v.
//
// The mapping from a spelling to a channel handle is pure string logic — no vendor DLL, no
// Windows API — and it is the identity two mappings are compared on (destination_key). Kept in
// a platform-neutral file so it can be unit-tested on the machine anyone actually develops on;
// living beside the driver made it compile only where nothing runs the tests, and a second
// implementation of these rules had already drifted once.
module transport

fn pcan_handle(s string) !u16 {
	t := s.trim_space()
	// EMPTY FIRST. `adapter: pcan` with no address composes to `pcan:`, and this used to index
	// t[0] on an empty string — a panic, in a validation pass whose whole job is to report a bad
	// configuration rather than die on one. It only became reachable when the resolver stopped
	// being Windows-only, which is the kind of thing widening a guard exposes.
	if t == '' {
		return error('empty PCAN channel — give the row an address (PCAN_USBBUS1, usb1, 1, or 0x51)')
	}
	low := t.to_lower()
	if low.starts_with('0x') {
		return u16(t.all_after('0x').parse_uint(16, 16) or {
			return error('bad PCAN handle "${t}"')
		})
	}
	mut n := -1
	if low.starts_with('pcan_usbbus') {
		n = low.all_after('pcan_usbbus').int()
	} else if low.starts_with('usb') {
		n = low.all_after('usb').int()
	} else if t[0].is_digit() {
		n = t.int()
	}
	if n >= 1 && n <= 8 {
		return u16(0x50 + n) // PCAN_USBBUS1 == 0x51
	}
	return error('unknown PCAN channel "${t}" (use PCAN_USBBUS1..8, usb1.., 1.., or 0x51)')
}
