// can_smoke — tiny CLI to exercise the transport module against a real bus.
//
//   can_smoke dump <iface>                 # print frames until Ctrl-C
//   can_smoke send <iface> <hexid> <hex>   # send one frame, e.g. send vcan0 123 DEADBEEF
//
// Cross-check against can-utils: `candump vcan0` vs our `send`, and `cansend`
// vs our `dump`.
module main

import os
import strconv
import transport

fn main() {
	args := os.args
	if args.len < 3 {
		eprintln('usage:\n  can_smoke dump <iface>\n  can_smoke send <iface> <hexid> <hexdata>')
		exit(2)
	}
	mode := args[1]
	iface := args[2]
	mut bus := transport.open_socketcan(iface) or {
		eprintln('error: ${err}')
		exit(1)
	}
	defer {
		bus.close()
	}

	match mode {
		'dump' {
			println('dumping ${iface} (Ctrl-C to stop)...')
			for {
				frame := bus.recv(-1) or {
					if err.msg() == 'timeout' {
						continue
					}
					eprintln('recv: ${err}')
					break
				}
				println('RX ${frame}')
			}
		}
		'send' {
			if args.len < 5 {
				eprintln('send needs <hexid> <hexdata>')
				exit(2)
			}
			id := parse_hex_u32(args[3])
			data := hex_to_bytes(args[4])
			frame := transport.CanFrame{
				id:       id
				extended: id > 0x7ff
				data:     data
			}
			bus.send(frame) or {
				eprintln('send: ${err}')
				exit(1)
			}
			println('TX ${frame}')
		}
		else {
			eprintln('unknown mode: ${mode}')
			exit(2)
		}
	}
}

fn parse_hex_u32(s string) u32 {
	clean := s.trim_string_left('0x').trim_string_left('0X')
	return u32(strconv.parse_uint(clean, 16, 32) or { 0 })
}

fn hex_to_bytes(s string) []u8 {
	mut clean := s.replace(' ', '').trim_string_left('0x')
	if clean.len % 2 != 0 {
		clean = '0' + clean
	}
	mut out := []u8{}
	for i := 0; i + 1 < clean.len + 1; i += 2 {
		if i + 2 > clean.len {
			break
		}
		out << u8(strconv.parse_uint(clean[i..i + 2], 16, 8) or { 0 })
	}
	return out
}
