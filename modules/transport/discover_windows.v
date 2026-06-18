module transport

// list_interfaces enumerates the bus interfaces available to scaffold into a project.
// Windows has no SocketCAN, so we query the installed vendor DLLs (canlib32 / PCANBasic)
// for attached channels (each backend's *_list() returns [] if its driver is absent),
// then append the always-available driver-free software buses.
pub fn list_interfaces() ![]Iface {
	mut out := []Iface{}
	out << kvaser_list() // canlib32.dll: physical + virtual Kvaser channels
	out << pcan_list()   // PCANBasic.dll: attached PCAN USB channels
	out << virtual_ifaces()
	return out
}
