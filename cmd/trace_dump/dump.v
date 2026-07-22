// trace_dump — headless smoke for the capture read-out path (blobly_emb trace dump).
//
// Freezes the target's ring(s) and dumps the selected cores over ISO-TP, reassembling each
// per-core block on the record id (flow control on the dump_fc id) and decoding the records —
// FB / thread / ISR intervals, epochs, and per-core block headers. This is the non-GUI twin of
// the blobly_net Trace Chart's dump worker; run it against emb's trace_multicore demo:
//
//   (emb)  examples/trace_multicore/bin/trace_multicore vcan0 &
//   v -path "@vlib|@vmodules|modules" run cmd/trace_dump/dump.v vcan0 0x0003 path/to/trace-manifest.csv
//
// args: [iface=vcan0] [core_mask=0] [manifest.csv]  (mask 0 = the single receiving core;
// 0x0003 = cores 0+1). The manifest supplies the config-driven trace frame ids; without it the
// trace_demo defaults (0x7E2..0x7E6) are used.
module main

import os
import transport
import isotp
import telem

fn main() {
	iface := if os.args.len > 1 { os.args[1] } else { 'vcan0' }
	mask := if os.args.len > 2 { u16(('0x' + os.args[2].trim_string_left('0x')).u64()) } else { u16(0) }

	// the trace frame ids are config-driven on the target; read them from the manifest if one was
	// passed, else fall back to the built-in trace_demo wire.
	mut f := telem.TraceFrames{}.or_defaults()
	if os.args.len > 3 {
		m := telem.load_manifest(os.args[3]) or {
			eprintln('load manifest ${os.args[3]}: ${err}')
			return
		}
		f = m.frames.or_defaults()
	}

	// host = ISO-TP receiver: send flow control on dump_fc, receive dump data on record. Open
	// first so the socket buffers the target's first frame before we command the dump. A 29-bit
	// trace id (> 0x7FF) must use extended addressing, else SocketCAN masks it to 11 bits.
	cmd_ext := f.cmd > 0x7ff
	mut ch := isotp.open_software(iface, f.dump_fc, f.record, f.record > 0x7ff) or {
		eprintln('open isotp on ${iface}: ${err}')
		return
	}
	mut bus := transport.open(iface) or {
		eprintln('open bus on ${iface}: ${err}')
		return
	}
	// freeze then dump the selected cores (one TraceCmd each on the cmd id).
	bus.send(transport.CanFrame{
		id:       f.cmd
		extended: cmd_ext
		data:     telem.encode_trace_cmd(telem.op_stop, telem.filter_all, mask)
	}) or {}
	bus.send(transport.CanFrame{
		id:       f.cmd
		extended: cmd_ext
		data:     telem.encode_trace_cmd(telem.op_dump, telem.filter_all, mask)
	}) or {}

	ncores := mask_popcount(mask)
	mut total := 0
	mut last_seen := 0 // cores whose final block (header_more == false) has arrived
	mut bi := 0
	for last_seen < ncores && bi < 256 {
		block := ch.recv(600) or {
			eprintln('block ${bi}: ${err}')
			break
		}
		// Same decoder the GUI Trace Chart uses, so this really is the non-GUI twin: timestamps
		// below are on the DUMPING core's timeline, with the epoch base applied and the
		// cross-core offset removed. Printing raw per-core start_us here would show a different
		// picture from the chart for the same dump.
		b := telem.decode_block(block)
		if !b.more {
			last_seen++
		}
		bi++
		println('--- block ${bi}: ${block.len} bytes (${block.len / 8} records) · core ${b.core}${if b.more {
			' (more follow)'
		} else {
			''
		}} ---')
		if b.skew_known {
			println('  [skew]    core ${b.core} clock is ${b.skew_us}us vs the dumping core (+/-${b.skew_bound_us}us) — applied below')
		} else if b.core != 0 {
			println('  [skew]    NOT MEASURED for core ${b.core} — times below are on its own clock')
		}
		for br in b.records {
			r := br.rec
			if r.kind() == telem.kind_thread {
				lbl := if r.is_idle() { 'idle' } else { 't${r.id()}' }
				println('  [thread]  ${lbl}  start ${br.abs_us}us  cpu ${r.cpu_us}us  reason ${r.reason()}')
			} else if r.kind() == telem.kind_isr {
				println('  [isr]     v${r.id()}  start ${br.abs_us}us  cpu ${r.cpu_us}us')
			} else {
				over := if r.flags() & telem.flag_overran != 0 { '  <- OVERRAN (trigger)' } else { '' }
				println('  handler ${r.id()}  start ${br.abs_us}us  cpu ${r.cpu_us}us${over}')
			}
			total++
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
