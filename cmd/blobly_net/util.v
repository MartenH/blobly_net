module main

import project
import candb
import sim

// mkbuf returns a fixed-size NUL-terminated input buffer seeded with `s`.
fn mkbuf(s string, size int) []u8 {
	mut b := []u8{len: size}
	for i, c in s {
		if i < size - 1 {
			b[i] = c
		}
	}
	return b
}

// parse_hex_bytes parses "DE AD BE" / "DEADBE" into bytes.
fn parse_hex_bytes(s string) []u8 {
	clean := s.replace(' ', '').replace('\t', '')
	mut out := []u8{}
	mut i := 0
	for i + 1 < clean.len + 1 && i + 2 <= clean.len {
		out << u8(('0x' + clean[i..i + 2]).u64())
		i += 2
	}
	return out
}

// build_node delegates to sim.from_project — the single implementation. This file, cmd/script
// and cmd/sim_startup_check each carried a byte-identical copy, so a change here (like adding
// end-to-end protection) reached the GUI and silently skipped the headless runner CI uses.
fn build_node(db candb.Database, cfg project.NodeCfg) sim.SimEcu {
	return sim.from_project(db, cfg)
}

fn hex(b []u8) string {
	mut p := []string{cap: b.len}
	for x in b {
		p << '${x:02X}'
	}
	return p.join(' ')
}
