// telem/manifest — the handler manifest (blobly_emb/docs/telemetry.md "Identity").
//
// loom2v assigns every handler a GLOBALLY-unique handler_id across all partitions and
// emits this table; blobly_net loads it next to the DBC and resolves the 1-byte id the
// target puts in every HandlerStat/Record back to a name / FB / core / period. Same file
// on both ends → the map can't drift, and the target never sends strings.
//
// Format: CSV (matches the doc's table; trivial for codegen to emit, no parser dep).
// Blank lines and `#` comments are ignored; an optional header row (first field "id"
// case-insensitive) is skipped. Columns:
//   id,partition,core,fb,handler,period_us
//   0,sense,1,SpeedFilter,on_10ms,10000
module telem

import os

// Handler is one row of the manifest.
pub struct Handler {
pub:
	id        u16 // the record entity id is 14-bit, so handler ids span 0..16383 (not just a byte)
	partition string
	core      int
	fb        string
	handler   string
	period_us u32
	thread    string // the [[partition.thread]] serving this handler (7th column; '' on old manifests)
}

// name is the FB.handler label used on lanes/legends.
pub fn (h Handler) name() string {
	return if h.fb != '' { '${h.fb}.${h.handler}' } else { h.handler }
}

// Thread is one thread (= partition) row: it labels the thread-switch (swimlane) lanes,
// whose from/to ids reference these. A separate id space from handlers.
pub struct Thread {
pub:
	id   u16 // 14-bit entity id space, same as handlers
	name string
	core int
	prio int = -1 // RTOS priority (5th column; -1 = unknown / no RTOS prio, e.g. host threads)
}

// TraceFrames are the five observability CAN ids from the manifest's `# trace frames` section
// (loom2v emits `frame,id,bus` rows there). The ids are config-driven on the target — a literal
// CAN id or a bus.dbc message name resolved to its id — so blobly_net must read them from the
// manifest rather than hardcode the trace_demo defaults. A zero field = "absent from the
// manifest"; or_defaults() fills those from the built-in id_* constants.
pub struct TraceFrames {
pub mut:
	cmd     u32 // host -> target capture control (id_trace_cmd)
	rsp     u32 // target -> host ack/status (id_trace_rsp)
	stat    u32 // unsolicited per-handler stats (id_handlerstat)
	record  u32 // ISO-TP dump payload (id_record)
	dump_fc u32 // ISO-TP flow control for the dump (id_dump_fc)
}

// ShellFrames are the CAN shell's three ids from the manifest's `# shell frames` section:
// the host sends one raw frame (the command line) on `input`, receives the ISO-TP response
// on `out`, and paces it with flow control on `fc`. (`input` because `in` is a keyword.)
pub struct ShellFrames {
pub mut:
	input u32 // host -> target: one raw frame = one command line
	fc    u32 // host -> target: ISO-TP flow control for the response
	out   u32 // target -> host: the response text (one ISO-TP block)
}

// or_defaults fills unset (0) ids with loom2v's [shell] defaults, so a manifest predating the
// shell section still reaches a default-configured target.
pub fn (f ShellFrames) or_defaults() ShellFrames {
	return ShellFrames{
		input: if f.input != 0 { f.input } else { 0x7f0 }
		fc:    if f.fc != 0 { f.fc } else { 0x7f2 }
		out:   if f.out != 0 { f.out } else { 0x7f1 }
	}
}

// or_defaults fills any unset (0) id from the built-in defaults, so an older manifest with no
// `# trace frames` section still yields the trace_demo wire.
pub fn (f TraceFrames) or_defaults() TraceFrames {
	return TraceFrames{
		cmd:     if f.cmd != 0 { f.cmd } else { id_trace_cmd }
		rsp:     if f.rsp != 0 { f.rsp } else { id_trace_rsp }
		stat:    if f.stat != 0 { f.stat } else { id_handlerstat }
		record:  if f.record != 0 { f.record } else { id_record }
		dump_fc: if f.dump_fc != 0 { f.dump_fc } else { id_dump_fc }
	}
}

// Manifest resolves handler_id -> Handler and thread_id -> Thread.
pub struct Manifest {
pub:
	handlers []Handler
	threads  []Thread
	frames   TraceFrames // the `# trace frames` ids (zero-filled -> or_defaults())
	shell    ShellFrames // the `# shell frames` ids (zero-filled -> or_defaults())
pub mut:
	by_id  map[u16]Handler // built by index()
	by_tid map[u32]Thread  // built by index(); key = tkey(core, id) — THREAD IDS ARE PER-CORE
	// (each core's recorder assigns first-sight ids from 1; the manifest mirrors that, so
	// two cores legitimately both have a t1)
}

// load_manifest reads + parses a manifest .csv file.
pub fn load_manifest(path string) !Manifest {
	return parse_manifest(os.read_file(path)!)
}

// parse_manifest parses manifest CSV text.
pub fn parse_manifest(text string) !Manifest {
	mut handlers := []Handler{}
	mut threads := []Thread{}
	mut frames := TraceFrames{}
	mut shellf := ShellFrames{}
	mut seen := map[u16]bool{}
	mut seen_tid := map[u32]bool{}
	// The manifest is sectioned by `#` header comments (`# fb.handlers:`, `# threads:`,
	// `# trace frames:`). Handler/thread rows self-identify by shape, but a trace-frame row
	// (`cmd,0x7e2,can0`) looks like a malformed handler row, so track the section to route it.
	mut section := ''
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if line == '' {
			continue
		}
		if line.starts_with('#') {
			low := line.to_lower()
			if low.contains('trace frames') {
				section = 'frames'
			} else if low.contains('shell frames') {
				section = 'shell'
			} else if low.contains('handlers') {
				section = 'handlers'
			} else if low.contains('threads') {
				section = 'threads'
			}
			continue
		}
		cols := line.split(',').map(it.trim_space())
		if section == 'frames' {
			// `frame,id,bus` — id is a literal CAN id (0x-hex or decimal); bus is ignored here.
			if cols.len < 2 {
				return error('manifest trace-frame row needs at least frame,id: "${line}"')
			}
			id := parse_can_id(cols[1]) or {
				return error('manifest trace-frame "${cols[0]}": ${err}')
			}
			match cols[0] {
				'cmd' { frames.cmd = id }
				'rsp' { frames.rsp = id }
				'stat' { frames.stat = id }
				'record' { frames.record = id }
				'dump_fc' { frames.dump_fc = id }
				else {} // unknown frame name — ignore (forward-compatible with new frames)
			}
			continue
		}
		if section == 'shell' {
			// `frame,id,bus` — same row shape as the trace-frames section.
			if cols.len < 2 {
				return error('manifest shell-frame row needs at least frame,id: "${line}"')
			}
			id := parse_can_id(cols[1]) or {
				return error('manifest shell-frame "${cols[0]}": ${err}')
			}
			match cols[0] {
				'in' { shellf.input = id }
				'fc' { shellf.fc = id }
				'out' { shellf.out = id }
				else {} // unknown frame name — ignore (forward-compatible)
			}
			continue
		}
		// A thread row labels a swimlane thread lane: `thread,<id>,<name>,<core>`. Ids are
		// PER-CORE (the same id on two cores is two threads); duplicates within one core
		// are still a manifest bug.
		if cols[0].to_lower() == 'thread' {
			if cols.len < 4 {
				return error('manifest thread row needs 4 columns (thread,id,name,core): "${line}"')
			}
			if !is_digits(cols[1]) || cols[1].int() > 16383 {
				return error('manifest thread id is not a 0..16383 number: "${cols[1]}"')
			}
			tid := u16(cols[1].int())
			if !is_digits(cols[3]) {
				return error('manifest thread core is not a number: "${cols[3]}"')
			}
			ck := tkey(cols[3].int(), tid)
			if ck in seen_tid {
				return error('manifest has a duplicate thread id on core ${cols[3]}: ${tid}')
			}
			seen_tid[ck] = true
			threads << Thread{
				id:   tid
				name: cols[2]
				core: cols[3].int()
				prio: if cols.len > 4 && cols[4] != '-' { cols[4].int() } else { -1 }
			}
			continue
		}
		if cols.len < 6 {
			return error('manifest row needs 6 columns (id,partition,core,fb,handler,period_us): "${line}"')
		}
		if cols[0].to_lower() == 'id' {
			continue // header row
		}
		// The wire id is a 14-bit entity id and its uniqueness is the manifest's contract — reject
		// a non-numeric / out-of-range / duplicate id rather than let a cast silently wrap it and
		// mislabel every record of the collided handler.
		if !is_digits(cols[0]) {
			return error('manifest handler id is not a number: "${cols[0]}"')
		}
		idnum := cols[0].int()
		if idnum > 16383 {
			return error('manifest handler id out of range 0..16383: ${idnum}')
		}
		id := u16(idnum)
		if id in seen {
			return error('manifest has a duplicate handler id: ${id}')
		}
		seen[id] = true
		// core + period_us must be numeric too — a silent conversion would accept
		// `0,p,x,F,h,oops` as zeros and hide a manifest/codegen mismatch, making the
		// per-core / jitter views wrong. period_us must be positive.
		if !is_digits(cols[2]) {
			return error('manifest core is not a number: "${cols[2]}"')
		}
		if !is_digits(cols[5]) || cols[5].u32() == 0 {
			return error('manifest period_us must be a positive number: "${cols[5]}"')
		}
		handlers << Handler{
			id:        id
			partition: cols[1]
			core:      cols[2].int()
			fb:        cols[3]
			handler:   cols[4]
			period_us: cols[5].u32()
			thread:    if cols.len > 6 { cols[6] } else { '' }
		}
	}
	if handlers.len == 0 {
		return error('manifest has no handler rows')
	}
	mut m := Manifest{
		handlers: handlers
		threads:  threads
		frames:   frames
		shell:    shellf
	}
	m.index()
	return m
}

// parse_can_id parses a manifest CAN id — `0x7e2` (hex) or decimal — into a u32.
fn parse_can_id(s string) !u32 {
	t := s.to_lower()
	if t.starts_with('0x') {
		hex := t[2..]
		if hex == '' {
			return error('empty hex id "${s}"')
		}
		mut v := u32(0)
		for c in hex {
			d := if c >= `0` && c <= `9` {
				u32(c - `0`)
			} else if c >= `a` && c <= `f` {
				u32(c - `a` + 10)
			} else {
				return error('bad hex digit in id "${s}"')
			}
			v = v * 16 + d
		}
		return v
	}
	if !is_digits(t) {
		return error('id is not a number: "${s}"')
	}
	return u32(t.u64())
}

// is_digits reports whether s is a non-empty run of ASCII digits (a valid unsigned id).
fn is_digits(s string) bool {
	if s == '' {
		return false
	}
	for c in s {
		if c < `0` || c > `9` {
			return false
		}
	}
	return true
}

// index (re)builds the by_id / by_tid lookups — call after mutating handlers/threads.
pub fn (mut m Manifest) index() {
	m.by_id = map[u16]Handler{}
	for h in m.handlers {
		m.by_id[h.id] = h
	}
	m.by_tid = map[u32]Thread{}
	for t in m.threads {
		m.by_tid[tkey(t.core, t.id)] = t
	}
}

// tkey packs (core, per-core thread id) into one lookup key — thread ids are only unique
// within a core (each core's recorder counts from 1).
pub fn tkey(core int, id u16) u32 {
	return (u32(core) << 16) | u32(id)
}

// thread_label resolves (core, thread_id) to a display name, synthesising "thread N" when
// unknown (an unlabelled or mismatched thread still gets a lane rather than crashing a view).
pub fn (m &Manifest) thread_label(core int, id u16) string {
	if t := m.by_tid[tkey(core, id)] {
		if t.name != '' {
			return t.name
		}
	}
	return 'thread ${id}'
}

// lookup resolves a handler_id; returns none for ids not in the manifest so the caller
// can fall back to a synthetic label (a target/manifest mismatch shouldn't crash a view).
pub fn (m &Manifest) lookup(id u16) ?Handler {
	return m.by_id[id] or { return none }
}

// label resolves a handler_id to a display name, synthesising "handler N" when unknown.
pub fn (m &Manifest) label(id u16) string {
	if h := m.lookup(id) {
		return h.name()
	}
	return 'handler ${id}'
}
