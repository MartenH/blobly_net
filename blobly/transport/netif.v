// netif — the host's network interfaces, and a multicast group joined on the one a caller names.
// A SOME/IP listener's group is joined on the default interface unless the row says which
// (`group_iface`, #334): on a host with a bench NIC beside a WSL, VPN or docker interface, a
// group offered on the bench NIC is otherwise not heard. The name is resolved to an interface
// INDEX and joined with MCAST_JOIN_GROUP, which takes an index for either family on Linux,
// macOS and Windows alike (netif_shim.h); the resolution is pure and tested (join_index).
module transport

import net

#flag windows -liphlpapi
#include "netif_shim.h"

fn C.ct_netif_list(buf &char, cap i32) i32
fn C.ct_netif_join(fd i64, v6 i32, group voidptr, len i32, ifindex u32) i32
fn C.ct_netif_strerror(code i32, buf &char, cap i32)

// NetIface is one address of one interface: its index for an IPv4 and for an IPv6 join (the same
// number but on Windows, where either may be 0 when the family is off), its name (Windows' friendly
// name, `Ethernet 2`), an alias it also answers to (Windows' adapter GUID; '' elsewhere), and the
// address as text ('' for an interface with none; an IPv6 link-local one carries its `%scope`).
pub struct NetIface {
pub:
	index4 u32
	index6 u32
	name   string
	alias  string
	addr   string
}

fn netif_error(code i32) string {
	mut buf := []u8{len: 256}
	C.ct_netif_strerror(-code, &char(buf.data), i32(buf.len))
	return unsafe { cstring_to_vstring(&char(buf.data)) }
}

// local_netifaces lists the host's interfaces, one entry per address.
pub fn local_netifaces() ![]NetIface {
	mut cap := 16384
	for _ in 0 .. 4 {
		mut buf := []u8{len: cap}
		n := C.ct_netif_list(&char(buf.data), i32(cap))
		if n < 0 {
			return error('cannot list the network interfaces: ${netif_error(n)}')
		}
		if int(n) > cap {
			cap = int(n) + 1024 // interfaces came and went between the two asks
			continue
		}
		return parse_netifaces(buf[..int(n)].bytestr())
	}
	return error('cannot list the network interfaces: the list kept growing')
}

// parse_netifaces reads ct_netif_list's lines.
fn parse_netifaces(text string) []NetIface {
	mut out := []NetIface{}
	for line in text.split('\n') {
		f := line.split('\t')
		if f.len != 5 {
			continue
		}
		out << NetIface{
			index4: u32(f[0].u64())
			index6: u32(f[1].u64())
			name:   f[2]
			alias:  f[3]
			addr:   f[4]
		}
	}
	return out
}

// join_index is the interface index a group of the family `v6` is joined on for `spec`: an
// interface by its name (or Windows' GUID), or by an address it holds (an IPv6 link-local one
// with or without its `%scope`). Refused by name: an interface the host does not have (naming
// the ones it has), an address several interfaces hold, and an interface with no index for the
// group's family.
pub fn join_index(ifaces []NetIface, spec string, v6 bool) !u32 {
	mut hit := []NetIface{}
	for f in ifaces {
		if f.name == spec || (f.alias != '' && f.alias == spec) || (f.addr != ''
			&& (f.addr == spec || f.addr.all_before('%') == spec)) {
			if !hit.any(it.name == f.name) {
				hit << f
			}
		}
	}
	if hit.len == 0 {
		mut names := []string{}
		for f in ifaces {
			if f.name !in names {
				names << f.name
			}
		}
		return error('no network interface "${spec}" on this host (by name or address; it has ${names.join(', ')})')
	}
	if hit.len > 1 {
		return error('${spec} is an address of several interfaces (${hit.map(it.name).join(', ')}); name the interface')
	}
	idx := if v6 { hit[0].index6 } else { hit[0].index4 }
	if idx == 0 {
		fam := if v6 { 'IPv6' } else { 'IPv4' }
		return error('interface "${hit[0].name}" has no ${fam} on this host')
	}
	return idx
}

// join_group_on joins `group` on the socket `c`, on the interface `spec` names (join_index).
pub fn join_group_on(mut c net.UdpConn, group string, spec string) ! {
	v6 := group.contains(':')
	if !is_multicast_addr(group) {
		return error('${group} is not a multicast address')
	}
	idx := join_index(local_netifaces()!, spec, v6)!
	at := if v6 { '[${group}]:0' } else { '${group}:0' }
	addrs := net.resolve_addrs(at, if v6 { net.AddrFamily.ip6 } else { net.AddrFamily.ip },
		.udp) or { return error('${group} is not a multicast address') }
	if addrs.len == 0 {
		return error('${group} is not a multicast address')
	}
	ga := addrs[0]
	r := C.ct_netif_join(i64(c.sock.handle), i32(if v6 { 1 } else { 0 }), voidptr(&ga),
		i32(ga.len()), idx)
	if r < 0 {
		return error(netif_error(r))
	}
}

// is_multicast_addr is whether `a` is an IPv4 (224.0.0.0/4) or IPv6 (ff00::/8) multicast literal.
fn is_multicast_addr(a string) bool {
	if a.contains(':') {
		return a.to_lower().starts_with('ff')
	}
	p := a.split('.')
	if p.len != 4 || p.any(it == '' || !it.bytes().all(it.is_digit()) || it.len > 3 || it.int() > 255) {
		return false
	}
	return p[0].int() >= 224 && p[0].int() <= 239
}
