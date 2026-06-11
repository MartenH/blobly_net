module transport

// list_interfaces enumerates the bus interfaces available to scaffold into a project.
// Windows has no SocketCAN, so only the driver-free software buses are offered. A vendor
// backend (PCAN/Vector/Kvaser) would enumerate real devices here later, via a *_windows.v
// addition — the seam is the same as open_windows.v.
pub fn list_interfaces() ![]Iface {
	return virtual_ifaces()
}
