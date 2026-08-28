module transport

import os

// list_interfaces enumerates the bus interfaces available to scaffold into a project.
// Windows has no SocketCAN, so we query the installed vendor DLLs (canlib32 / PCANBasic)
// for attached channels (each backend's *_list() returns [] if its driver is absent),
// then append the always-available driver-free software buses.
pub fn list_interfaces() ![]Iface {
	mut out := []Iface{}
	out << kvaser_list() // canlib32.dll: physical + virtual Kvaser channels
	out << pcan_list() // PCANBasic.dll: attached PCAN USB channels
	out << vector_list() // vxlapi64.dll: application channels with hardware assigned
	out << virtual_ifaces()
	return out
}

// local_ipv4_addrs is every IPv4 address this host has, loopback excluded -- the interfaces an
// mDNS query has to leave through (cansub_mdns.v). `ipconfig` lists a USB network adapter's
// subnet where resolving the host's own name may not; the parsing is in local_addrs.v, tested
// against an English and a German listing. Unverified on a Windows bench as of #235.
fn local_ipv4_addrs() []string {
	res := os.execute('ipconfig')
	if res.exit_code != 0 {
		return []
	}
	return ipv4_addrs_from_ipconfig(res.output)
}
