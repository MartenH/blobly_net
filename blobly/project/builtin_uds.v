module project

import blobly.transport

// builtin_uds_off: an enabled CAN row on `row`'s wire says `builtin_uds: false`, so the built-in
// 0x7E0/0x7E8 diagnostic server is not started there. One server is seeded per wire, so any
// enabled row of the wire counts; the GUI and the headless runner both ask this.
pub fn builtin_uds_off(rows []Channel, row Channel) bool {
	dest := transport.destination_key_for(row.adapter, row.iface)
	return rows.any(it.enabled && it.kind() == .can && !it.builtin_uds
		&& transport.destination_key_for(it.adapter, it.iface) == dest)
}
