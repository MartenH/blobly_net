module foldrule

// WHOSE RECEIVE STATE IS THIS ROW'S? (#336)
//
// The Buses panel, the Network panel and the toolbar fold what the readers recorded — read or
// not, link down, fault ladder, last RX, backend counts — by a key, and every row then draws
// the state filed under its key. On a CAN wire that key is the DESTINATION: several rows may
// spell one wire, ONE reader serves it, and only that reader's row is ever written, so every
// alias must show what the reader saw or a dead wire looks fine on its other rows.
//
// An Ethernet row is not an alias of anything. Each DoIP or SOME/IP row has its OWN reader
// (its own connection, its own listener), and two of them naming one endpoint are a conflict
// the endpoint claim settles by refusing one — not two spellings sharing a reader. Folding
// them by interface drew the refused row's `last RX` from the sibling that won the claim. So
// the row IS the identity: what an Ethernet row listens to is exactly what its own reader
// received, and nothing another row recorded.
//
// `dest` is the row's transport.destination_key, `row` its project row index (Chan.proj_idx).
// '/' cannot occur in a network interface name, and every other destination key carries its
// adapter's prefix, so the Ethernet key cannot equal one a CAN row is folded under.
pub fn key(dest string, eth bool, row int) string {
	if eth {
		return 'eth/row${row}'
	}
	return dest
}
