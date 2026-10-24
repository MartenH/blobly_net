module transport

import os
import json2

// Minimal projection of `ip -details -json link show` — V's json.decode ignores the many
// other fields. A CAN/vcan netdev has linkinfo.info_kind == "can"/"vcan"; a configured real
// `can0` also carries linkinfo.info_data.bittiming.bitrate (vcan has none → 0).
pub struct IpLink {
	ifname   string
	mtu      int
	linkinfo IpLinkInfo
}

pub struct IpLinkInfo {
	info_kind string
	info_data IpInfoData
}

pub struct IpInfoData {
	bittiming IpBittiming
}

pub struct IpBittiming {
	bitrate int
}

// list_interfaces enumerates real SocketCAN interfaces (vcan0/can0…) via iproute2, then
// appends the driver-free software buses. If `ip` is missing or errors, we still return the
// virtual fallbacks rather than failing — discovery should degrade gracefully.
pub fn list_interfaces() ![]Iface {
	mut out := []Iface{}
	res := os.exec(['ip', '-details', '-json', 'link', 'show'])
	if res.exit_code == 0 {
		links := json2.decode[[]IpLink](res.output) or { []IpLink{} }
		for l in links {
			kind := l.linkinfo.info_kind
			if kind != 'can' && kind != 'vcan' {
				continue
			}
			out << Iface{
				name:    l.ifname
				iface:   l.ifname
				kind:    kind
				bitrate: l.linkinfo.info_data.bittiming.bitrate
				virtual: false
				fd:      fd_of_mtu(l.mtu)
			}
		}
	}
	out << virtual_ifaces()
	return out
}

// sysfs_can_ifaces is every CAN link in /sys/class/net, the down ones too (`ip -json` leaves
// some out), each with a description: a real adapter's USB product, bus path and link state, so
// the two channels of a dual adapter read as "PCAN-USB Pro FD [1-1]" and its sibling.
fn sysfs_can_ifaces() []Interface {
	mut out := []Interface{}
	names := os.ls('/sys/class/net') or { return out }
	for name in names {
		base := '/sys/class/net/${name}'
		typ := os.read_file('${base}/type') or { continue }
		if typ.trim_space() != '280' { // ARPHRD_CAN
			continue
		}
		is_vcan := name.starts_with('vcan')
		mut desc := 'virtual CAN'
		if !is_vcan {
			product := (os.read_file('${base}/device/../product') or { '' }).trim_space()
			state := (os.read_file('${base}/operstate') or { '' }).trim_space()
			busnum := (os.read_file('${base}/device/../busnum') or { '' }).trim_space()
			devpath := (os.read_file('${base}/device/../devpath') or { '' }).trim_space()
			mut parts := [if product != '' { product } else { 'CAN' }]
			if busnum != '' && devpath != '' {
				parts << '[${busnum}-${devpath}]'
			}
			if state != '' {
				parts << '· ${state}'
			}
			desc = parts.join(' ')
		}
		mtu := (os.read_file('${base}/mtu') or { '' }).trim_space().int()
		out << Interface{
			address: name
			kind:    if is_vcan { 'vcan' } else { 'socketcan' }
			desc:    desc
			fd:      fd_of_mtu(mtu)
			virtual: is_vcan
		}
	}
	out.sort(a.address < b.address)
	return out
}

// local_ipv4_addrs is every IPv4 address this host has, loopback excluded -- the interfaces an
// mDNS query has to leave through (cansub_mdns.v). The parsing is in local_addrs.v, tested.
fn local_ipv4_addrs() []string {
	res := os.exec(['ip', '-4', '-j', 'addr'])
	if res.exit_code != 0 {
		return []
	}
	return ipv4_addrs_from_ip_json(res.output)
}
