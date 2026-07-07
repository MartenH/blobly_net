// trace_dump — headless smoke for the capture read-out path (blobly_emb trace dump).
//
// Freezes the target's ring(s) and dumps the selected cores over ISO-TP, reassembling each
// per-core block on 0x7E5 (flow control on 0x7E6) and decoding the records — handler runs,
// thread switches, and per-core block headers. This is the non-GUI twin of the blobly_vgui
// Trace Chart's dump worker; run it against emb's trace_multicore demo:
//
//   (emb)  examples/trace_multicore/bin/trace_multicore vcan0 &
//   v -path "@vlib|@vmodules|modules" run cmd/trace_dump/dump.v vcan0 0x0003
//
// args: [iface=vcan0] [core_mask=0]  (mask 0 = the single receiving core; 0x0003 = cores 0+1)
module main

import os
import transport
import isotp
import telem

fn main() {
	iface := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	mask := if os.args.len > 2 { u16(('0x' + os.args[2].trim_string_left('0x')).u64()) } else { u16(0) }

	// host = ISO-TP receiver: send flow control on 0x7E6, receive dump data on 0x7E5. Open
	// first so the socket buffers the target's first frame before we command the dump.
	mut ch := isotp.open_software(iface, telem.id_dump_fc, telem.id_record, false) or {
		eprintln('open isotp on ${iface}: ${err}')
		return
	}
	mut bus := transport.open(iface) or {
		eprintln('open bus on ${iface}: ${err}')
		return
	}
	// freeze then dump the selected cores (one TraceCmd each on 0x7E2).
	bus.send(transport.CanFrame{
		id:   telem.id_trace_cmd
		data: telem.encode_trace_cmd(telem.op_stop, telem.filter_all, mask)
	}) or {}
	bus.send(transport.CanFrame{
		id:   telem.id_trace_cmd
		data: telem.encode_trace_cmd(telem.op_dump, telem.filter_all, mask)
	}) or {}

	nblocks := mask_popcount(mask)
	mut total := 0
	for bi in 0 .. nblocks {
		block := ch.recv(600) or {
			eprintln('block ${bi}: ${err}')
			break
		}
		println('--- block ${bi}: ${block.len} bytes (${block.len / 8} records) ---')
		for off := 0; off + 8 <= block.len; off += 8 {
			r := telem.decode_record(block[off..off + 8])
			if r.is_header() {
				println('  [header]  core ${r.header_core()}  count ${r.header_count()}')
			} else if r.is_switch() {
				println('  [switch]  t${r.from_thread()} -> t${r.to_thread()}  reason ${r.reason()}  @${r.start_us}us')
				total++
			} else {
				println('  handler ${r.handler_id}  start ${r.start_us}us  cpu ${r.cpu_us}us')
				total++
			}
		}
	}
	println('total timeline records: ${total}')
	ch.close()
	bus.close()
}

// mask_popcount counts the cores a dump mask selects (a 0 mask means the single core 0).
fn mask_popcount(mask u16) int {
	if mask == 0 {
		return 1
	}
	mut m := mask
	mut n := 0
	for m != 0 {
		n += int(m & 1)
		m >>= 1
	}
	return n
}
