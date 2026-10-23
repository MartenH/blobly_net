module udsconn

import blobly.isotp
import blobly.transport

// resolve_isotp is the raw ISO-TP channel `a` asks for on row `name` of carrier `car`: a CAN row
// only (ISO-TP is a CAN transport), both ids given (a raw channel carries no protocol whose
// default pair it could take), 29-bit when either is past 0x7FF, as resolve's.
pub fn resolve_isotp(a Ask, name string, car Carrier) !Target {
	check_ids(a, name)!
	if k := car.eth_kind() {
		return error('${a.what}("${name}"): a ${k} channel carries no ISO-TP; a raw ISO-TP channel opens on a CAN row')
	}
	if !a.has_tx || !a.has_rx {
		return error('${a.what}("${name}"): give both tx and rx; a raw ISO-TP channel has no default pair')
	}
	return resolve(a, name, car)
}

// open_isotp is the ISO-TP channel of CAN target `t` on row `name`: the software state machine on
// the bus `opener` gives for `iface` (and the row's name), framed as the wire declares — a UDS
// connection's channel and a raw one alike.
pub fn open_isotp(t Target, name string, iface string, opener fn (string, string) !transport.Bus) !&isotp.SoftChannel {
	bus := opener(iface, name) or { return error('isotp open failed on ${name}: ${err}') }
	return isotp.on_bus(bus, iface, t.tx, t.rx, t.ext) or {
		return error('isotp open failed on ${name}: ${err}')
	}
}
