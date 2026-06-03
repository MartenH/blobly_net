// isotp_smoke — send one ISO-TP PDU and print the peer's reply. Exercises the
// kernel ISO-TP path end-to-end (multi-frame if the payload is > 7 bytes).
//
//   v -path "@vlib|@vmodules|modules" run cmd/isotp_smoke/smoke.v [iface] [tx_hex] [rx_hex] [data_hex]
// defaults: vcan0 7E0 7E8 000102030405060708090A0B0C0D0E0F10111213
module main

import isotp
import os

fn main() {
	a := os.args
	iface := if a.len > 1 { a[1] } else { 'vcan0' }
	tx := if a.len > 2 { parse_hex(a[2]) } else { u32(0x7E0) }
	rx := if a.len > 3 { parse_hex(a[3]) } else { u32(0x7E8) }
	payload := if a.len > 4 { hex_to_bytes(a[4]) } else { []u8{len: 20, init: u8(index)} }

	mut ch := isotp.open(iface, tx, rx, false) or {
		eprintln('open failed: ${err}')
		exit(1)
	}
	defer { ch.close() }

	println('TX (${payload.len}B): ${hex(payload)}')
	reply := isotp.request(mut ch, payload, 2000) or {
		eprintln('request failed: ${err}')
		exit(1)
	}
	println('RX (${reply.len}B): ${hex(reply)}')
}

fn hex(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X}'
	}
	return s
}

fn parse_hex(s string) u32 {
	mut v := u32(0)
	for c in s {
		d := hex_digit(c) or { continue }
		v = v * 16 + u32(d)
	}
	return v
}

fn hex_to_bytes(h string) []u8 {
	mut out := []u8{}
	mut i := 0
	for i + 1 < h.len {
		hi := hex_digit(h[i]) or { break }
		lo := hex_digit(h[i + 1]) or { break }
		out << u8(hi * 16 + lo)
		i += 2
	}
	return out
}

fn hex_digit(c u8) ?int {
	if c >= `0` && c <= `9` {
		return int(c - `0`)
	}
	if c >= `a` && c <= `f` {
		return int(c - `a`) + 10
	}
	if c >= `A` && c <= `F` {
		return int(c - `A`) + 10
	}
	return none
}
