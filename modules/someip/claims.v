// claims — who in THIS PROCESS is already listening on a SOME/IP endpoint.
//
// It exists because the bind cannot answer the question. This V sets SO_REUSEADDR inside its
// private UDP socket constructor, before the bind, so a second listener on a held port succeeds
// and the kernel then delivers each unicast datagram to exactly ONE of the two sockets: the
// stream is split, in silence, and whichever surface is missing messages has nothing to say
// about why. Across processes that is unfixable from here and is documented rather than
// promised away (docs/bus_config_dialog.md). WITHIN one process it is fixable, and this is the
// fix: every listener claims its endpoint first, and a second claim on an overlapping one is
// refused by name.
//
// SYMMETRIC BY CONSTRUCTION, which is the whole point. The GUI channel's reader and a Lua
// `someip.listen` window take the same lock in the same way, so it does not matter which starts
// first: script-then-Start refuses the row (the Log says which script holds it), Start-then-
// script refuses the script (the error names the channel). A snapshot taken when the script
// environment was built could only ever answer one of those two orderings — it was the earlier
// shape here, and it answered the wrong one whenever the script began while the GUI was stopped.
//
// Overlap is the kernel's rule, not a string comparison: a wildcard bind covers every address on
// its port, so 0.0.0.0:30491 and 127.0.0.1:30491 overlap although they are spelled differently.
// Two different specific addresses on one port do not overlap — two NICs, two listeners.
//
// Requires `-enable-globals`, V's idiom for process-global state, as transport's inproc registry
// already does.
module someip

import net

// Claim is one live listener: where it binds, and who to name in a refusal.
struct Claim {
	host  string
	port  int
	owner string // 'channel ETH1' / 'a script' — read back verbatim in the refusal
}

struct Claims {
mut:
	live []Claim
}

__global (
	someip_claims shared Claims
)

// wildcard_host reports whether this bind address covers every address on its port.
fn wildcard_host(h string) bool {
	return h == '' || h == '0.0.0.0' || h == '::' || h == '[::]'
}

// canonical_host is the address a bind on `host` will ACTUALLY use, which is what two claims
// have to be compared on. Two spellings of one address — `localhost` and `127.0.0.1`,
// `LOCALHOST` and `localhost`, a hostname and the address it resolves to — are different strings
// and the same socket, so comparing the strings accepted both claims and let the kernel split
// the stream between them: the registry would have been defeated by a synonym.
//
// Resolved through the same call `net.listen_udp` uses, so the answer cannot disagree with the
// bind. A name that does not resolve falls back to its lowercased spelling: the bind is about to
// fail anyway and will say so, and a claim is never the right place to report a bad address.
// The wildcard is answered without resolving — it is the one host whose meaning is a rule rather
// than an address.
fn canonical_host(host string) string {
	if wildcard_host(host) {
		return '0.0.0.0'
	}
	h := host.trim_space().trim('[]')
	addrs := net.resolve_addrs(bind_addr(h, 1), .unspec, .udp) or {
		return h.to_lower()
	}
	if addrs.len == 0 {
		return h.to_lower()
	}
	// the address without the port we passed only to make it resolvable
	s := addrs[0].str()
	return if i := s.last_index(':') { s[..i].trim('[]') } else { s }
}

// overlaps: could one datagram be delivered to either of these two binds?
fn overlaps(ha string, pa int, hb string, pb int) bool {
	if pa != pb {
		return false
	}
	if wildcard_host(ha) || wildcard_host(hb) {
		return true
	}
	return ha == hb
}

// claim_endpoint registers `owner` as the listener on host:port, or fails naming who already is.
// Every listener in this process calls it before binding, and calls release_endpoint when it
// closes — the GUI row for the life of its run, a Lua window for the life of its window.
pub fn claim_endpoint(host string, port int, owner string) ! {
	canon := canonical_host(host)
	mut held := ''
	lock someip_claims {
		for c in someip_claims.live {
			if overlaps(canon, port, c.host, c.port) {
				held = c.owner
				break
			}
		}
		if held == '' {
			someip_claims.live << Claim{
				host:  canon
				port:  port
				owner: owner
			}
		}
	}
	if held != '' {
		return error('${held} is already listening there — a second socket on that port would SPLIT the stream, not share it (each datagram reaches only one of them)')
	}
}

// release_endpoint drops the claim `owner` holds on host:port. Safe to call when none is held,
// so a caller may release unconditionally on its way out.
pub fn release_endpoint(host string, port int, owner string) {
	canon := canonical_host(host)
	lock someip_claims {
		for i, c in someip_claims.live {
			if c.owner == owner && c.host == canon && c.port == port {
				someip_claims.live.delete(i)
				return
			}
		}
	}
}
