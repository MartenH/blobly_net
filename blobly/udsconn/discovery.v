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
	if car.kind != .doip {
		return error('"${from}" is not a DoIP channel')
	}
	return transport.listen_port(port, from, car.port, doip.port, 'entity')!, ip6
		|| doip.addr_family(car.host) == .ip6
}

// SomeipListen is where a SOME/IP listener listens: the bind host ('' the wildcard), the port,
// the multicast group ('' none) and the interface it is joined on ('' the default).
pub struct SomeipListen {
pub:
	host        string
	port        int
	group       string
	group_iface string
}

// someip_listener is where a SOME/IP listener listens: the port asked for (0: 30490) and the
// group and its interface asked for on the wildcard, or — given `row`, the carrier of the SOME/IP
// row named `from` — that row's bind host, port, group and interface. A port, a group or an
// interface differing from the row's is refused, not overruled; a row with no group is a unicast
// listener, so a group asked of it differs too, and a row joining on the default interface
// differs from one named. An interface is compared as the one it names on this host
// (transport.same_netif), so its name and an address it holds are one.
pub fn someip_listener(port int, group string, group_iface string, from string, row ?Carrier) !SomeipListen {
	car := row or {
		return SomeipListen{
			port:        transport.listen_port(port, '', none, someip.default_port, 'listener')!
			group:       group
			group_iface: group_iface
		}
	}
	if car.kind != .someip {
		return error('"${from}" is not a SOME/IP channel')
	}
	if group != '' && group != car.group {
		joins := if car.group == '' { 'joins no multicast group' } else { 'joins ${car.group}' }
		return error('group ${group} contradicts from = "${from}", whose listener ${joins}; give one or the other')
	}
	if group_iface != '' && !(car.group_iface != ''
		&& transport.same_netif(group_iface, car.group_iface, car.group)) {
		on := if car.group == '' {
			'joins no multicast group'
		} else if car.group_iface == '' {
			'joins ${car.group} on the default interface'
		} else {
			'joins ${car.group} on ${car.group_iface}'
		}
		return error('group_iface ${group_iface} contradicts from = "${from}", whose listener ${on}; give one or the other')
	}
	return SomeipListen{
		host:        car.host
		port:        transport.listen_port(port, from, car.port, someip.default_port, 'listener')!
		group:       car.group
		group_iface: car.group_iface
	}
}
