module udsconn

import blobly.sysview

// row_ref is a row as the system model reaches a node on it (sysview.System.reach): its name and
// what its carrier addresses — the Lua uds.node and the C ABI's bb_node_reach build theirs here.
pub fn row_ref(name string, car Carrier) sysview.RowRef {
	return sysview.RowRef{
		name:    name
		doip:    car.doip
		eth:     car.someip
		host:    car.host
		logical: car.ecu
	}
}
