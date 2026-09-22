// mf4_dump — native-V MF4 reader smoke test / oracle-diff tool.
// Parses an .mf4 with modules/mf4 and prints a frame summary (count, unique IDs,
// first frames). Compare against sut/mf4_bridge.py / asammdf for cross-validation.
//
//   v -path "@vlib|@vmodules|modules" run cmd/mf4_dump/mf4_dump.v <file.mf4> [--all] [--stream]
//
// --stream reads the file through mf4.Stream (docs/streaming_replay.md) instead of the
// whole-file loader, and prints the heap high-water mark it saw — the number the two paths are
// compared on. Without it the loader runs and reports its own.
module main

import os
import mf4
import canlog

fn main() {
	if os.args.len < 2 {
		eprintln('usage: mf4_dump <file.mf4> [--all] [--stream]')
		exit(1)
	}
	path := os.args[1]
	show_all := '--all' in os.args[2..]
	stream := '--stream' in os.args[2..]
	mut peak := u64(0)
	entries := if stream {
		mut src := mf4.open_source(path) or {
			eprintln('open failed: ${err}')
			exit(1)
		}
		mut s := mf4.open_stream(mut src) or {
			eprintln('parse failed: ${err}')
			exit(1)
		}
		mut log := canlog.Log{}
		mut n := 0
		for {
			r := s.next(mut log) or { break }
			log.rows << r
			n++
			if n % 4096 == 0 {
				peak = heap_peak(peak)
			}
		}
		peak = heap_peak(peak)
		src.close()
		if s.err != '' {
			// a cursor that stopped on a broken block is a parse failure, as the loader's is —
			// not a shorter recording reported as a clean one
			eprintln('parse failed: ${s.err}')
			exit(1)
		}
		println('stream: forced ${s.forced}, evicted ${s.evicted}, refused ${s.refused}, unresolved ${s.unresolved}, out of order ${s.out_of_order}, read-ahead high-water ${s.max_queued} rows / ${s.max_ahead_s * 1000.0:.1f} ms, writer disorder ${s.max_disorder_s * 1000.0:.1f} ms, clock steps ${s.clock_steps}')
		// the loader branch's mark includes the []LogEntry it returns, so this one is taken
		// after the same conversion or the two numbers do not compare
		es := log.entries()
		peak = heap_peak(peak)
		es
	} else {
		es := mf4.load_file(path) or {
			eprintln('parse failed: ${err}')
			exit(1)
		}
		peak = heap_peak(peak)
		es
	}
	kind := if stream { 'stream' } else { 'loader' }
	println('heap high-water mark: ${f64(peak) / (1024.0 * 1024.0):.1f} MB (${kind})')
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

// heap_peak is the larger of the mark so far and the heap in use now.
fn heap_peak(so_far u64) u64 {
	now := u64(gc_memory_use())
	return if now > so_far { now } else { so_far }
}

fn hexbytes(b []u8) string {
	mut s := ''
	for x in b {
		s += '${x:02X}'
	}
	return s
}
