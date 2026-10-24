module udsconn

import blobly.sysview
import blobly.transport

// row_ref is a row as the system model reaches a node on it (sysview.System.reach): its name, what
// its carrier addresses, the wire a CAN row is (`iface`, transport.destination_key) and whether a
// DoIP row hosts its entity (`hosts`, project.Channel.hosts_doip_entity) — the Lua uds.node and the
// C ABI's bb_node_reach build theirs here.
pub fn row_ref(name string, iface string, car Carrier, hosts bool) sysview.RowRef {
	return sysview.RowRef{
		name:    name
		doip:    car.doip
		eth:     car.someip
		host:    car.host
		logical: car.ecu
		wire:    if car.doip || car.someip { '' } else { transport.destination_key(iface) }
		hosts:   car.doip && hosts
	}
}
