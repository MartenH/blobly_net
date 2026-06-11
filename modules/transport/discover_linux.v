module transport

import os
import json

// Minimal projection of `ip -details -json link show` — V's json.decode ignores the many
// other fields. A CAN/vcan netdev has linkinfo.info_kind == "can"/"vcan"; a configured real
// `can0` also carries linkinfo.info_data.bittiming.bitrate (vcan has none → 0).
struct ipLink {
	ifname   string
	linkinfo ipLinkInfo
}

struct ipLinkInfo {
	info_kind string
	info_data ipInfoData
}

struct ipInfoData {
	bittiming ipBittiming
}

struct ipBittiming {
	bitrate int
}

// list_interfaces enumerates real SocketCAN interfaces (vcan0/can0…) via iproute2, then
// appends the driver-free software buses. If `ip` is missing or errors, we still return the
// virtual fallbacks rather than failing — discovery should degrade gracefully.
pub fn list_interfaces() ![]Iface {
	mut out := []Iface{}
	res := os.execute('ip -details -json link show')
	if res.exit_code == 0 {
		links := json.decode([]ipLink, res.output) or { []ipLink{} }
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
			}
		}
	}
	out << virtual_ifaces()
	return out
}
