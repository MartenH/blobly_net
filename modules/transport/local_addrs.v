module transport

import json

// The IPv4 addresses this host has, for a multicast query that must leave through every
// interface (cansub_mdns.v). The enumeration is per platform -- `ip -j addr` on Linux,
// `ipconfig` on Windows -- but the PARSING is here, pure and tested, because a text format a
// distro or a locale can vary is exactly the kind of input that fails silently inside a
// platform file CI never runs (the `*_names.v` precedent).

struct IpAddrInfo {
	family string
	local  string
}

struct IpAddrEntry {
	ifname    string
	addr_info []IpAddrInfo
}

// ipv4_addrs_from_ip_json reads `ip -4 -j addr` output: every inet address on every interface
// but loopback -- by NAME, because WSL2's mirrored networking puts a routable address on `lo`.
pub fn ipv4_addrs_from_ip_json(text string) []string {
	mut out := []string{}
	entries := json.decode([]IpAddrEntry, text) or { return out }
	for e in entries {
		if e.ifname == 'lo' {
			continue
		}
		for a in e.addr_info {
			if a.family == 'inet' && a.local != '' && a.local !in out {
				out << a.local
			}
		}
	}
	return out
}

// ipv4_addrs_from_ipconfig reads `ipconfig` output in any locale: the label is localised
// ("IPv4 Address", "IPv4-Adresse", "IPv4-adress"), the token "IPv4" and the dotted quad after
// the colon are not.
pub fn ipv4_addrs_from_ipconfig(text string) []string {
	mut out := []string{}
	for line in text.split_into_lines() {
		if !line.contains('IPv4') || !line.contains(':') {
			continue
		}
		mut v := line.all_after_last(':').trim_space()
		// `(Preferred)` and its translations trail the address on some Windows versions.
		v = v.all_before('(').trim_space()
		if is_dotted_quad(v) && !v.starts_with('127.') && v !in out {
			out << v
		}
	}
	return out
}

fn is_dotted_quad(s string) bool {
	parts := s.split('.')
	if parts.len != 4 {
		return false
	}
	for p in parts {
		if p.len == 0 || p.len > 3 || !p.bytes().all(it.is_digit()) || p.int() > 255 {
			return false
		}
	}
	return true
}
