module sysview

import toml
import blobly.isotp

// addressing.v — how blobly_emb states a diagnostic connection's CAN ids, read the way its tools
// read them (blobly_emb tools/ecumodel addressing.v, docs/can-tp.md §2): an [isotp] table's rx_id /
// tx_id and a system.toml node's diag req / rsp alike, by
//   - normal addressing: the ids as given, 11-bit, or 29-bit with `ext = true`;
//   - normal fixed addressing (`addressing = "normal_fixed"`): the node's own address `sa` and the
//     tester's `ta`, one byte each, from which the 29-bit ids derive (fixed_id).
// The format is part of a node's identity: a node declared 29-bit is addressed only as 29-bit,
// whatever its ids' numbers.

// fixed_id is a normal fixed addressing identifier (ISO 15765-2 §10.3.3), priority 6: PF 0xDA for
// a physical request or answer, 0xDB for a functional request, then the target address and the
// source address — 0x18DA<target><source>. The mirror of blobly_emb's comm/isotp fixed_id, pinned
// by the same golden vectors (addressing_test.v): a node at `sa` talking to tester `ta` receives
// requests on fixed_id(false, sa, ta) and answers on fixed_id(false, ta, sa).
pub fn fixed_id(functional bool, target u8, source u8) u32 {
	pf := if functional { u32(0xDB) } else { u32(0xDA) }
	return u32(6) << 26 | pf << 16 | u32(target) << 8 | u32(source)
}

// Addressing is a table's diagnostic ids as read: the request and response ids and whether they are
// 29-bit, `errs` each thing in it blobly_emb refuses (said in the table's terms, the caller naming
// the table), and `unreadable` where the ids cannot be read at all — an addressing this reader does
// not know, a normal fixed pair missing an address, an `ext` that is not a boolean. An unreadable
// table addresses nothing (0, 0), and nothing stands in for it: a tester never talks normal-addressed
// 11-bit ISO-TP to a node configured otherwise.
struct Addressing {
	req        u32
	rsp        u32
	ext        bool
	unreadable bool
	errs       []string
}

// addressing_formats: the `addressing` values blobly_emb takes (its cfgschema's choices)
const addressing_formats = ['normal', 'normal_fixed']

// addressing_of reads a table's request and response ids (under `rx_key` / `tx_key` with normal
// addressing, derived from sa and ta under normal fixed addressing) and whether they are 29-bit
// (`ext = true`, or normal fixed addressing). A key that belongs to the other addressing is said and
// not read. Under normal addressing a table stating neither id states no ids (a dissolved node's
// [isotp] takes its system diag; a diag with neither is no allocation), and one stating a single
// id, or an id that is not an integer or does not fit its width (29 bits, or 11 without `ext`), is
// unreadable: blobly_emb refuses each, and a pair read past one would address the node on an id the
// system never gave it.
fn addressing_of(m map[string]toml.Any, rx_key string, tx_key string) Addressing {
	mut fixed := false
	if a := m['addressing'] {
		if a is string && a in addressing_formats {
			fixed = a == 'normal_fixed'
		} else {
			shown := if a is string { '"${a}"' } else { a.to_toml() }
			return Addressing{
				unreadable: true
				errs:       ['addressing ${shown} is not "normal" or "normal_fixed" (extended and mixed addressing are not supported); it addresses nothing']
			}
		}
	}
	mut errs := []string{}
	if fixed {
		for key in [rx_key, tx_key, 'functional_id', 'ext'] {
			if key in m {
				errs << '${key} is given with addressing = "normal_fixed", whose ids derive from sa and ta; not read'
			}
		}
		// both asked before either is judged, so a table missing both says both
		sa := fixed_address(m, 'sa', "the node's own address", mut errs)
		ta := fixed_address(m, 'ta', "the tester's address", mut errs)
		if s := sa {
			if t := ta {
				return Addressing{
					req:  fixed_id(false, s, t)
					rsp:  fixed_id(false, t, s)
					ext:  true
					errs: errs
				}
			}
		}
		return Addressing{
			ext:        true
			unreadable: true
			errs:       errs
		}
	}
	for key in ['sa', 'ta', 'functional_ta'] {
		if key in m {
			errs << '${key} is for addressing = "normal_fixed"; normal addressing states ${rx_key} and ${tx_key}; not read'
		}
	}
	mut ext := false
	if v := m['ext'] {
		if v !is bool {
			errs << 'ext = ${v.to_toml()} is not a boolean (true: the ids are 29-bit); it addresses nothing'
			return Addressing{
				unreadable: true
				errs:       errs
			}
		}
		ext = v as bool
	}
	// both asked before either is judged, so a table with two bad ids says both
	req := normal_id(m, rx_key, ext, mut errs)
	rsp := normal_id(m, tx_key, ext, mut errs)
	if req.bad || rsp.bad {
		return Addressing{
			ext:        ext
			unreadable: true
			errs:       errs
		}
	}
	if req.given != rsp.given {
		given, missing := if req.given { rx_key, tx_key } else { tx_key, rx_key }
		errs << 'gives ${given} without ${missing} (normal addressing states both); it addresses nothing'
		return Addressing{
			ext:        ext
			unreadable: true
			errs:       errs
		}
	}
	return Addressing{
		req:  req.id
		rsp:  rsp.id
		ext:  ext
		errs: errs
	}
}

// NormalId is one id of normal addressing as read: `given` where the key is present, `bad` where it
// is present and cannot be read (the reason in the caller's errs)
struct NormalId {
	id    u32
	given bool
	bad   bool
}

// normal_id reads normal addressing's id `key`: an integer within 29 bits, and within 11 unless
// `ext` — blobly_emb's bounds (an id above 0x7FF without ext is refused there, never promoted)
fn normal_id(m map[string]toml.Any, key string, ext bool, mut errs []string) NormalId {
	v := m[key] or { return NormalId{} }
	if v !is i64 {
		errs << '${key} = ${v.to_toml()} is not an integer CAN id; it addresses nothing'
		return NormalId{
			given: true
			bad:   true
		}
	}
	n := v as i64
	shown := if n < 0 { n.str() } else { '0x${n:X}' }
	if n < 0 || n > i64(isotp.ext_id_max) {
		errs << '${key} = ${shown} is out of range (0x0..0x${isotp.ext_id_max:X}); it addresses nothing'
	} else if !ext && n > i64(isotp.std_id_max) {
		errs << '${key} = ${shown} is above 0x${isotp.std_id_max:X}, an 11-bit id (ext = true makes the ids 29-bit); it addresses nothing'
	} else {
		return NormalId{
			id:    u32(n)
			given: true
		}
	}
	return NormalId{
		given: true
		bad:   true
	}
}

// fixed_address is an address of normal fixed addressing, `key` — an integer 0..255 — or none, the
// reason added to `errs`: a pair missing one, or holding something else, addresses nothing.
fn fixed_address(m map[string]toml.Any, key string, what string, mut errs []string) ?u8 {
	v := m[key] or {
		errs << 'addressing = "normal_fixed" needs ${key} (${what}, 0..255); it addresses nothing'
		return none
	}
	if v is i64 && v >= 0 && v <= 255 {
		return u8(v)
	}
	errs << '${key} = ${v.to_toml()} is not an address (0..255); it addresses nothing'
	return none
}
