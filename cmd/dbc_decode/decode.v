// dbc_decode — load a DBC and decode one CAN frame to physical signal values.
// Machine-readable output (one `Name=value` per line) so the Python oracle can
// diff V's decode against an independent implementation.
//
//   v -path "@vlib|@vmodules|modules" run cmd/dbc_decode/decode.v <dbc> <id_hex> <data_hex>
//   e.g.  ... dbc/blobly_net.dbc 100 1234ABCD00000000
module main

import candb
import os
import strconv

fn main() {
	args := os.args
	if args.len < 4 {
		eprintln('usage: dbc_decode <dbc_path> <id_hex> <data_hex>')
		exit(2)
	}
	db := candb.load_dbc_file(args[1]) or { panic('load dbc: ${err}') }
	id := u32(strconv.parse_uint(args[2], 16, 32) or { panic('bad id hex: ${args[2]}') })
	data := hex_to_bytes(args[3])

	msg := db.lookup(id) or {
		eprintln('no message 0x${id:X} in DBC')
		exit(1)
	}
	for s in msg.signals {
		// fixed 6-decimal format keeps the comparison exact across languages
		println('${s.name}=${s.physical(data):.6f}')
	}
}

fn hex_to_bytes(h string) []u8 {
	mut out := []u8{}
	mut i := 0
	for i + 1 < h.len {
		out << u8(strconv.parse_uint(h[i..i + 2], 16, 8) or { 0 })
		i += 2
	}
	return out
}
