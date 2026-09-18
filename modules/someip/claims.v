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

// ClaimKind says what sort of listener holds a claim, because a caller has to treat the two
// differently: a row's claim from a PREVIOUS run is about to be released and is worth waiting
// for, while a script's window is a live measurement and must be refused at once.
pub enum ClaimKind {
	row    // a channel row's reader, owned by a run
	script // a Lua listening window
}

// Claim is one live listener: where it binds, what sort it is, and who to name in a refusal.
struct Claim {
	host  string
	port  int
	owner string // 'channel ETH1' / 'a script' — read back verbatim in the refusal
	kind  ClaimKind
}

// ClaimHeld is the refusal, carrying WHO holds the endpoint and what sort they are, so the
// caller can decide rather than parse a sentence.
pub struct ClaimHeld {
pub:
	owner string
	kind  ClaimKind
}

pub fn (e ClaimHeld) msg() string {
	return '${e.owner} is already listening there — a second socket on that port would SPLIT the stream, not share it (each datagram reaches only one of them)'
}

pub fn (e ClaimHeld) code() int {
	return 0
}

struct Claims {
mut:
	live []Claim
}

__global (
	someip_claims shared Claims
)

// wildcard_host reports whether this bind address is a wildcard at all — for the group rule,
// which only cares that a socket is not pinned to one address.
fn wildcard_host(h string) bool {
	return h == '' || h == '0.0.0.0' || h == '::' || h == '[::]'
}

// is_v6 classifies a canonical address by family. Canonical form has no brackets, so a colon
// can only be an IPv6 separator.
fn is_v6(h string) bool {
	return h.contains(':')
}

// covers reports whether a socket bound to `a` receives what is addressed to `b`.
//
// THE FAMILIES ARE NOT ONE WILDCARD. `0.0.0.0` is the IPv4 wildcard and receives nothing sent to
// an IPv6 address, so a row on it and a row on `[::1]` are two disjoint listeners that Linux is
// happy to have at once — treating them as a conflict left a valid dual-stack project with an
// idle row. `::` is the exception in the other direction: this V enables dual-stack on every
// IPv6 socket it makes (new_udp_socket → set_dualstack(true)), so a bind there does receive IPv4
// as well, and it covers both families.
fn covers(a string, b string) bool {
	if a == b {
		return true
	}
	if a == '::' {
		return true // dual-stack, per V's own socket setup
	}
	if a == '0.0.0.0' {
		return !is_v6(b)
	}
	return false
}

// canonical_host is the address a bind on `host` will ACTUALLY use, which is what two claims
// have to be compared on. Two spellings of one address — `localhost` and `127.0.0.1`,
// `LOCALHOST` and `localhost`, a hostname and the address it resolves to — are different strings
// and the same socket, so comparing the strings accepted both claims and let the kernel split
// the stream between them: the registry would have been defeated by a synonym.
//
// THE SAME CALL, AND THE SAME ELEMENT, as `net.listen_udp`: it resolves with
// `resolve_addrs_fuzzy` and binds `addrs[0]`, so canonicalising any other way would produce an
// authority that disagrees with the bind it is supposed to describe. That distinction is not
// academic — `localhost` is 127.0.0.1 on one machine and ::1 on another (the CI runner is the
// second), and on the second it genuinely IS a different socket from 127.0.0.1, so folding the
// two by name would invent a collision that the kernel does not have. Asking the resolver gets
// both machines right for the same reason: it is the question the bind asks.
//
// A name that does not resolve keeps its lowercased spelling — the bind is about to fail and
// will say so, and a claim is never the right place to diagnose an address. The wildcard is
// answered without resolving, being the one host whose meaning is a rule rather than an address.
fn canonical_host(host string) string {
	h0 := host.trim_space().trim('[]')
	if h0 == '' || h0 == '0.0.0.0' {
		return '0.0.0.0'
	}
	if h0 == '::' {
		return '::' // kept distinct: it covers both families where 0.0.0.0 covers one
	}
	h := h0
	addrs := net.resolve_addrs_fuzzy(bind_addr(h, 1), .udp) or { return h.to_lower() }
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
	return covers(ha, hb) || covers(hb, ha)
}

// claim_endpoint registers `owner` as the listener on host:port, or fails naming who already is.
// Every listener in this process calls it before binding, and calls release_endpoint when it
// closes — the GUI row for the life of its run, a Lua window for the life of its window.
// It RETURNS the canonical host it claimed, and the caller must bind exactly that. Resolving
// twice is not the same as resolving once: `net.listen_udp` resolves the name again, and a
// hostname whose DNS answer changes between the two would leave the registry holding address A
// while the socket sits on address B — a second listener on B accepted, the stream split, and
// the registry none the wiser. Releasing takes the same canonical value back, so a changed
// answer cannot strand a claim either.
pub fn claim_endpoint(host string, port int, owner string, kind ClaimKind) !string {
	canon := canonical_host(host)
	mut held := Claim{}
	mut found := false
	lock someip_claims {
		for c in someip_claims.live {
			if overlaps(canon, port, c.host, c.port) {
				held = c
				found = true
				break
			}
		}
		if !found {
			someip_claims.live << Claim{
				host:  canon
				port:  port
				owner: owner
				kind:  kind
			}
		}
	}
	if found {
		return ClaimHeld{
			owner: held.owner
			kind:  held.kind
		}
	}
	return canon
}

// release_endpoint drops the claim `owner` holds on host:port. Safe to call when none is held,
// so a caller may release unconditionally on its way out.
// `canon_host` is the value claim_endpoint RETURNED, not the configured spelling: re-resolving
// here would strand the claim whenever the answer had changed since.
pub fn release_endpoint(canon_host string, port int, owner string) {
	lock someip_claims {
		for i, c in someip_claims.live {
			if c.owner == owner && c.host == canon_host && c.port == port {
				someip_claims.live.delete(i)
				return
			}
		}
	}
}
