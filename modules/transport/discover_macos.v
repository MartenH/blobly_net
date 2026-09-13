module transport

import os

// list_interfaces enumerates the bus interfaces available to scaffold into a project.
// macOS has no SocketCAN and no vendor DLL to query (PCAN/Kvaser/Vector XL are Windows-only),
// so there is nothing real to enumerate — only the always-available driver-free software buses,
// same as Windows without any of its vendor drivers installed.
pub fn list_interfaces() ![]Iface {
	mut out := []Iface{}
	out << virtual_ifaces()
	return out
}

// local_ipv4_addrs is every IPv4 address this host has, loopback excluded -- the interfaces an
// mDNS query has to leave through (cansub_mdns.v). `ifconfig` is the BSD/macOS tool for this
// (Linux uses `ip -4 -j addr`, Windows `ipconfig`); the parsing is in local_addrs.v, tested.
fn local_ipv4_addrs() []string {
	res := os.execute('ifconfig')
	if res.exit_code != 0 {
		return []
	}
	return ipv4_addrs_from_ifconfig(res.output)
}
