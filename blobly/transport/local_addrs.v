module transport

import json2
import time

// The IPv4 addresses this host has, for a multicast query that must leave through every
// interface (cansub_mdns.v). The enumeration is per platform -- `ip -j addr` on Linux,
// `ipconfig` on Windows, `ifconfig` on macOS -- but the PARSING is here, pure and tested,
// because a text format a distro or a locale can vary is exactly the kind of input that fails
// silently inside a platform file CI never runs (the `*_names.v` precedent).

pub struct IpAddrInfo {
	family string
	local  string
}

pub struct IpAddrEntry {
	ifname    string
	addr_info []IpAddrInfo
}

// ipv4_addrs_from_ip_json reads `ip -4 -j addr` output: every inet address on every interface
// but loopback -- by NAME, because WSL2's mirrored networking puts a routable address on `lo`.
pub fn ipv4_addrs_from_ip_json(text string) []string {
	mut out := []string{}
	entries := json2.decode[[]IpAddrEntry](text) or { return out }
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

// ipv4_addrs_from_ifconfig reads BSD/macOS `ifconfig` output: an `inet ` line (not `inet6`) on
// any interface, second whitespace-separated token, loopback (127.x) excluded — same filter as
// the ipconfig parser above, and simpler than tracking interface names into `lo0`, since a
// routable 127.x address is not a thing this parser needs to special-case for (unlike WSL2's
// mirrored `lo` above, macOS has no analogous quirk to guard against).
pub fn ipv4_addrs_from_ifconfig(text string) []string {
	mut out := []string{}
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if !line.starts_with('inet ') {
			continue
		}
		parts := line.split(' ').filter(it != '')
		if parts.len < 2 {
			continue
		}
		v := parts[1]
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

// How often a wait for an enumeration in progress looks at its result (ms).
const ipv4_addrs_poll_ms = 2

// One enumeration at a time, numbered: a caller waits for the one in progress, or the one it
// started, and a command that stalls holds one thread, not one per browse.
struct Ipv4Enum {
mut:
	addrs   []string
	done    u64 // the number of the last enumeration that finished
	running u64 // the number of the one in progress; 0: none
	next    u64
}

__global (
	ipv4_enum shared Ipv4Enum
)

// ipv4_enum_skipped is whether an enumeration asked at `now` with deadline `until` (time.ticks();
// 0: none) is not run at all: its deadline has passed.
fn ipv4_enum_skipped(now i64, until i64) bool {
	return until > 0 && now >= until
}

// local_ipv4_addrs_until is local_ipv4_addrs within `until` (time.ticks(); 0: no bound): none when
// the deadline passes first. The command runs on a thread of its own, so a stalled one costs the
// caller its deadline and no more.
fn local_ipv4_addrs_until(until i64) ?[]string {
	if ipv4_enum_skipped(time.ticks(), until) {
		return none
	}
	mut want := u64(0)
	mut start := false
	lock ipv4_enum {
		if ipv4_enum.running == 0 {
			ipv4_enum.next++
			ipv4_enum.running = ipv4_enum.next
			start = true
		}
		want = ipv4_enum.running
	}
	if start {
		spawn enumerate_ipv4(want)
	}
	for {
		mut done := false
		mut got := []string{}
		rlock ipv4_enum {
			if ipv4_enum.done >= want {
				done = true
				got = ipv4_enum.addrs.clone()
			}
		}
		if done {
			return got
		}
		mut nap := i64(ipv4_addrs_poll_ms)
		if until > 0 {
			left := until - time.ticks()
			if left <= 0 {
				return none
			}
			nap = if left < nap { left } else { nap }
		}
		time.sleep(nap * time.millisecond)
	}
	return none
}

// enumerate_ipv4 runs enumeration number `n` and publishes its addresses.
fn enumerate_ipv4(n u64) {
	addrs := local_ipv4_addrs()
	lock ipv4_enum {
		ipv4_enum.addrs = addrs
		ipv4_enum.done = n
		ipv4_enum.running = 0
	}
}
