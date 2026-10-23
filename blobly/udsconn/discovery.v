module udsconn

import blobly.doip
import blobly.someip
import blobly.transport

// doip_listener is where a DoIP announcement listener listens, and whether over IPv6: the port
// asked for (0: 13400) and the family asked for, or — given `car`, the carrier of the row named
// `from` — that row's port and, besides, its address's family. An IPv6 entity announces to ff02::1, which
// only a v6 listener that joined the group hears; the family is read off the address literal,
// doip's one rule (doip.addr_family), the one the entity announces by — so a host name that
// resolves to IPv6 only is read as v4 here as it is there (docs/doip.md).
pub fn doip_listener(port int, ip6 bool, from string, row ?Carrier) !(int, bool) {
	car := row or { return transport.listen_port(port, '', none, doip.port, 'entity')!, ip6 }
	if !car.doip {
		return error('"${from}" is not a DoIP channel')
	}
	return transport.listen_port(port, from, car.port, doip.port, 'entity')!, ip6
		|| doip.addr_family(car.host) == .ip6
}

// someip_listener is where a SOME/IP listener listens — bind host, port and multicast group: the
// port asked for (0: 30490) and the group asked for on the wildcard, or — given `row`, the carrier
// of the SOME/IP row named `from` — that row's bind host, port and group. A port, or a group,
// differing from the row's is refused, not overruled; a row with no group is a unicast listener,
// so a group asked of it differs too.
pub fn someip_listener(port int, group string, from string, row ?Carrier) !(string, int, string) {
	car := row or {
		return '', transport.listen_port(port, '', none, someip.default_port, 'listener')!, group
	}
	if !car.someip {
		return error('"${from}" is not a SOME/IP channel')
	}
	if group != '' && group != car.group {
		joins := if car.group == '' { 'joins no multicast group' } else { 'joins ${car.group}' }
		return error('group ${group} contradicts from = "${from}", whose listener ${joins}; give one or the other')
	}
	return car.host, transport.listen_port(port, from, car.port, someip.default_port, 'listener')!, car.group
}
