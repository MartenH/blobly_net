// mf4_dump — native-V MF4 reader smoke test / oracle-diff tool.
// Parses an .mf4 with modules/mf4 and prints a frame summary (count, unique IDs,
// first frames). Compare against sut/mf4_bridge.py / asammdf for cross-validation.
//
//   v -path "@vlib|@vmodules|modules" run cmd/mf4_dump/mf4_dump.v <file.mf4> [--all]
module main

import os
import mf4

fn main() {
	if os.args.len < 2 {
		eprintln('usage: mf4_dump <file.mf4> [--all]')
		exit(1)
	}
	path := os.args[1]
	show_all := os.args.len > 2 && os.args[2] == '--all'
	entries := mf4.load_file(path) or {
		eprintln('parse failed: ${err}')
		exit(1)
	}
	mut counts := map[u32]int{}
	for e in entries {
		counts[e.frame.id]++
	}
	println('${path}: ${entries.len} frames, ${counts.len} unique IDs')
	if entries.len > 0 {
		println('time span: ${entries[0].t_s:.5f} .. ${entries[entries.len - 1].t_s:.5f} s')
	}
	if show_all {
		for e in entries {
			println('${e.t_s:.6f} 0x${e.frame.id:X} dlc=${e.frame.data.len} ${hexbytes(e.frame.data)}')
		}
	} else {
		println('first 6 frames:')
		for i := 0; i < 6 && i < entries.len; i++ {
			e := entries[i]
			ext := if e.frame.extended { 'x' } else { ' ' }
			println('  t=${e.t_s:.5f} ${ext} 0x${e.frame.id:X} dlc=${e.frame.data.len} ${hexbytes(e.frame.data)}')
		}
	}
}

fn hexbytes(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X}'
	}
	return s
}
