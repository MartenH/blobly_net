module project

import blobly.transport

// wire_rates is what a frame on `iface`'s wire is priced at for its bus load: ONE answer per
// wire, whichever row asks — the nominal rate of the first of `rows` on the wire (unset is
// default_bitrate) and the data rate of the first that declares one (0: none). `rows` is the
// caller's enabled rows in project order; no CAN row on the wire is default_bitrate classic.
// Rows are matched by wire_key, so an address with its vendor rate and one without are one wire.
pub fn wire_rates(rows []Channel, iface string) (int, int) {
	key := transport.wire_key(iface)
	mut nominal := 0
	mut data := 0
	for c in rows {
		if c.is_eth() || transport.wire_key(c.iface) != key {
			continue
		}
		if nominal == 0 {
			nominal = c.nominal_bitrate()
		}
		if data == 0 && c.data_bitrate > 0 {
			data = c.data_bitrate
		}
	}
	return if nominal > 0 { nominal } else { default_bitrate }, data
}
