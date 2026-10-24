module project

import blobly.transport

// wire_rates is what a frame on `iface`'s wire is priced at for its bus load: ONE answer per
// wire, whichever row asks — the nominal rate of the first of `rows` on the wire (unset is
// default_bitrate) and the data rate of the first that declares one (0: none). `rows` is the
// caller's enabled rows in project order; none when no CAN row of them is on the wire, for the
// caller's own fallback. The wire is the address without its rate (transport.wire_key), so a
// bare vendor address finds the row that states one.
pub fn wire_rates(rows []Channel, iface string) ?(int, int) {
	key := transport.wire_key(iface)
	mut nominal := 0
	mut data := 0
	for c in rows {
		if c.is_eth() || transport.wire_key(c.iface_with_bitrate()) != key {
			continue
		}
		if nominal == 0 {
			nominal = c.nominal_bitrate()
		}
		if data == 0 && c.data_bitrate > 0 {
			data = c.data_bitrate
		}
	}
	if nominal == 0 {
		return none
	}
	return nominal, data
}

// address_rates is the rates an interface states itself — a vendor address's `@<arb>[/<data>]` —
// else default_bitrate classic: the price of a wire no row names.
pub fn address_rates(iface string) (int, int) {
	if transport.adapter_configures_bitrate(iface.all_before(':')) && iface.contains('@') {
		tok := iface.all_after_last('@').all_before(',')
		if arb, data, fd := transport.vendor_split_fd_rate(tok, default_bitrate) {
			return arb, if fd { data } else { 0 }
		}
	}
	return default_bitrate, 0
}
