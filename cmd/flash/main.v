module main

// flash — the host flasher CLI: drives a blobly bootloader's UDS programming
// session (blobly_emb docs/bootloader.md) over ISO-TP on SocketCAN. The whole
// session lives in modules/flash (shared with the GUI's Flash panel); this
// file is argument parsing + a println sink.
//
//   v run cmd/flash <iface> <image.bin|.img> [base_hex] [req_id_hex] [rsp_id_hex] [sw_version]
//   v run cmd/flash vcan0 app.bin 08020000 7B0 7B8 1
import os
import isotp
import flash

struct StdoutSink {
mut:
	last_pct int = -1
}

fn (mut s StdoutSink) note(msg string) {
	println('flash: ${msg}')
}

fn (mut s StdoutSink) block(done int, total int) {
	pct := if total > 0 { done * 100 / total } else { 100 }
	if pct / 10 != s.last_pct / 10 || done == total {
		println('flash: transfer ${done}/${total} blocks (${pct}%)')
		s.last_pct = pct
	}
}

fn main() {
	if os.args.len < 3 {
		eprintln('usage: flash <iface> <image.bin|.img> [base_hex=08020000] [req=7B0] [rsp=7B8] [sw_version=1]')
		exit(2)
	}
	iface := os.args[1]
	image := os.read_bytes(os.args[2]) or {
		eprintln('flash: read ${os.args[2]}: ${err}')
		exit(1)
	}
	base := u32('0x${if os.args.len > 3 { os.args[3] } else { '08020000' }}'.u64())
	req_id := u32('0x${if os.args.len > 4 { os.args[4] } else { '7B0' }}'.u64())
	rsp_id := u32('0x${if os.args.len > 5 { os.args[5] } else { '7B8' }}'.u64())
	sw_version := u32(if os.args.len > 6 { os.args[6].u64() } else { 1 })

	// 0x29 tester private seed: $BLOBLY_FLASH_SEED (64 hex chars) or the dev seed.
	// A malformed env value is an error (never a silent fall-through to the dev key).
	seed := flash.tester_seed(os.getenv('BLOBLY_FLASH_SEED')) or {
		eprintln('flash: BLOBLY_FLASH_SEED: ${err}')
		exit(2)
	}

	mut ch := isotp.open_software(iface, req_id, rsp_id, false) or {
		eprintln('flash: open ${iface}: ${err}')
		exit(1)
	}
	defer {
		ch.close()
	}
	println('flash: ${os.args[2]} -> ${iface} @0x${base.hex()}, sw_version ${sw_version}')
	mut sink := StdoutSink{}
	flash.program(mut ch, image, flash.Opts{ base: base, sw_version: sw_version, auth_seed: seed }, mut sink) or {
		eprintln('flash: ${err}')
		exit(1)
	}
}

