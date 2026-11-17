module sysview

import toml

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

// addressing_of reads a table's request and response ids (under `rx_key` / `tx_key` with normal
// addressing) and whether they are 29-bit. Under normal fixed addressing the ids derive from sa and
// ta — (0, 0, false) when either is missing or not an integer 0..255, which blobly_emb refuses, so
// nothing invents an address it never had. `ext` counts only as the boolean true; an id that is
// not an integer reads 0, as elsewhere here.
fn addressing_of(m map[string]toml.Any, rx_key string, tx_key string) (u32, u32, bool) {
	if a := m['addressing'] {
		if a is string && a == 'normal_fixed' {
			sa := one_byte(m, 'sa') or { return 0, 0, false }
			ta := one_byte(m, 'ta') or { return 0, 0, false }
			return fixed_id(false, sa, ta), fixed_id(false, ta, sa), true
		}
	}
	mut ext := false
	if v := m['ext'] {
		ext = v is bool && v
	}
	return u32(tint(m, rx_key)), u32(tint(m, tx_key)), ext
}

// one_byte: an address of normal fixed addressing — an integer 0..255, none for anything else
fn one_byte(m map[string]toml.Any, key string) ?u8 {
	v := m[key] or { return none }
	if v is i64 && v >= 0 && v <= 255 {
		return u8(v)
	}
	return none
}
