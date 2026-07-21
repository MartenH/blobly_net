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
// SomeipIdent is the manifest's `# someip:` identity row — the eth service
// the image binds (service, interface version, its own port, the configured
// peer endpoint). Present only for eth images; service == 0 means absent.
pub struct SomeipIdent {
pub mut:
	service u16
	version u8
	port    u16
	peer    string
}

// EthFrame is one `ethframe` row: a SOME/IP frame the image exchanges on its
// eth bus. `dir` is the TARGET's perspective (tx = board -> host, the events a
// host channel receives). The id fixes the frame's identity and `length` its
// exact payload size — the rx path drops any other length.
pub struct EthFrame {
pub:
	name     string
	id       u16
	length   int
	dir      string // 'tx' | 'rx'
	mode     string // 'cyclic' | 'event'
	cycle_us u32
	e2e      u16 // e2e data id ('-' in the manifest = 0 = unprotected)
}

// EthField is one `ethlayout` row: a payload field of an eth frame. Fields are
// LITTLE-endian at byte offsets (the blobly payload contract; the SOME/IP
// header itself is big-endian).
pub struct EthField {
pub:
	frame  string
	signal string
	field  string
	offset int
	width  int
	typ    string // u8/u16/u32/u64 or i8/i16/i32/i64 (i* sign-extend on decode)
}

// decode reads this field's little-endian value from an event payload; none
// when the payload is too short for the field (a torn/foreign layout must
// read as absent, not as garbage).
pub fn (f EthField) decode(payload []u8) ?i64 {
	if f.offset < 0 || f.width < 1 || f.offset + f.width > payload.len {
		return none
	}
	mut v := u64(0)
	for k in 0 .. f.width {
		v |= u64(payload[f.offset + k]) << (8 * k)
	}
	if f.typ.starts_with('i') && f.width < 8 {
		sign := u64(1) << (8 * f.width - 1)
		if v & sign != 0 {
			v |= ~(sign * 2 - 1) // sign-extend from the wire width
		}
	}
	return i64(v)
}

// format renders the decoded value for display: unsigned types print the raw
// bits as u64 (a u64 above i64 max must not show negative — decode carries
// the bit pattern through i64), signed i* keep the sign extension.
pub fn (f EthField) format(payload []u8) ?string {
	v := f.decode(payload)?
	if f.typ.starts_with('i') {
		return '${v}'
	}
	return '${u64(v)}'
}

pub struct Manifest {
pub:
	handlers     []Handler
	threads      []Thread
	frames       TraceFrames // the `# trace frames` ids (zero-filled -> or_defaults())
	shell        ShellFrames // the `# shell frames` ids (zero-filled -> or_defaults())
	someip       SomeipIdent // the `# someip:` identity (eth images; service 0 = none)
	shell_method u16         // `ethmod,shell,method,<id>` — the eth RPC shell (0 = none)
	eth_frames   []EthFrame  // `ethframe` rows — the image's eth bus frames
	eth_layout   []EthField  // `ethlayout` rows — payload fields of those frames
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
	mut sip := SomeipIdent{}
	mut shell_method := u16(0)
	mut eth_frames := []EthFrame{}
	mut eth_layout := []EthField{}
	mut seen_eth := map[u16]bool{}
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
			} else if low.contains('someip') {
				section = 'someip'
			} else if low.contains('eth modules') {
				section = 'ethmod'
			} else if low.contains('handlers') {
				section = 'handlers'
			} else if low.contains('threads') {
				section = 'threads'
			}
			continue
		}
		cols := line.split(',').map(it.trim_space())
		// ethframe/ethlayout rows self-identify by their first column and are routed
		// BEFORE the section blocks: their `# eth frames:` / `# eth layout:` headers
		// match no section, so the someip/ethmod blocks above would otherwise eat them.
		// Malformed values fail the LOAD (same rule as someip rows): a silently-dropped
		// frame would just lose the channel's rx with no visible reason.
		if cols[0] == 'ethframe' {
			// `ethframe,<name>,<id>,<len>,<dir>,<mode>,<cycle_us>,<e2e_id>`
			if cols.len < 5 {
				return error('manifest ethframe row needs name,id,len,dir: "${line}"')
			}
			fid := parse_can_id(cols[2]) or { return error('manifest ethframe "${cols[1]}": ${err}') }
			if fid == 0 || fid > 0xFFFF {
				return error('manifest ethframe id 0x${fid.hex()} out of range (1..0xFFFF)')
			}
			if !is_digits(cols[3]) || cols[3].int() == 0 {
				return error('manifest ethframe len must be a positive number: "${cols[3]}"')
			}
			if cols[4] != 'tx' && cols[4] != 'rx' {
				return error('manifest ethframe dir must be tx or rx: "${cols[4]}"')
			}
			// a tx (board->host) frame arrives as a NOTIFICATION, whose id must
			// carry the event-class bit — without it every datagram would fail
			// the rx envelope check and the channel would run at 100% drops.
			// rx frames are the board's business (its own gate governs them).
			if cols[4] == 'tx' && fid & 0x8000 == 0 {
				return error('manifest ethframe "${cols[1]}" is tx but id 0x${fid.hex()} lacks the event bit (0x8000)')
			}
			// duplicate ids would split identity between the by-id lookup (first
			// wins) and a rx map built from the rows (last wins) — reject.
			if u16(fid) in seen_eth {
				return error('manifest has a duplicate ethframe id: 0x${fid.hex()}')
			}
			seen_eth[u16(fid)] = true
			mut e2e := u32(0)
			if cols.len > 7 && cols[7] != '-' {
				e2e = parse_can_id(cols[7]) or { return error('manifest ethframe e2e id: ${err}') }
			}
			eth_frames << EthFrame{
				name:     cols[1]
				id:       u16(fid)
				length:   cols[3].int()
				dir:      cols[4]
				mode:     if cols.len > 5 { cols[5] } else { '' }
				cycle_us: if cols.len > 6 { cols[6].u32() } else { 0 }
				e2e:      u16(e2e)
			}
			continue
		}
		if cols[0] == 'ethlayout' {
			// `ethlayout,<frame>,<signal>,<field>,<offset>,<width>,<type>`
			if cols.len < 7 {
				return error('manifest ethlayout row needs frame,signal,field,offset,width,type: "${line}"')
			}
			if !is_digits(cols[4]) || !is_digits(cols[5]) || cols[5].int() < 1 || cols[5].int() > 8 {
				return error('manifest ethlayout ${cols[1]}.${cols[3]}: offset must be numeric and width 1..8: "${line}"')
			}
			eth_layout << EthField{
				frame:  cols[1]
				signal: cols[2]
				field:  cols[3]
				offset: cols[4].int()
				width:  cols[5].int()
				typ:    cols[6]
			}
			continue
		}
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
		if section == 'someip' {
			// `someip,service,version,port,peer` — the eth service identity.
			// Malformed values fail the LOAD: a silently-zero service would
			// just disable the eth shell with no visible reason.
			if cols[0] == 'someip' && cols.len < 5 {
				return error('manifest someip row needs service,version,port,peer: "${line}"')
			}
			if cols.len >= 5 && cols[0] == 'someip' {
				svc := parse_can_id(cols[1]) or { return error('manifest someip service: ${err}') }
				if svc == 0 || svc > 0xFFFF {
					return error('manifest someip service 0x${svc.hex()} out of range (1..0xFFFF)')
				}
				ver := cols[2].int()
				if ver < 0 || ver > 255 || (cols[2] != '0' && ver == 0) {
					return error('manifest someip version "${cols[2]}" is not 0..255')
				}
				prt := cols[3].int()
				if prt < 1 || prt > 65535 {
					return error('manifest someip port "${cols[3]}" is not 1..65535')
				}
				sip.service = u16(svc)
				sip.version = u8(ver)
				sip.port = u16(prt)
				sip.peer = cols[4]
			}
			continue
		}
		if section == 'ethmod' {
			// `ethmod,<module>,<endpoint>,<id>` — module endpoints on the eth
			// bus; the shell's method id is the one the RPC client dials.
			if cols.len < 4 && cols.len >= 2 && cols[0] == 'ethmod' && cols[1] == 'shell' {
				return error('manifest ethmod shell row needs its method id: "${line}"')
			}
			if cols.len >= 4 && cols[0] == 'ethmod' && cols[1] == 'shell' && cols[2] == 'method' {
				mid := parse_can_id(cols[3]) or { return error('manifest shell method: ${err}') }
				if mid == 0 || mid > 0x7FFF {
					return error('manifest shell method 0x${mid.hex()} is not a method id (1..0x7FFF)')
				}
				shell_method = u16(mid)
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
	// cross-validate the layouts at the END (row order independent): every
	// ethlayout row must reference a declared ethframe and fit inside its
	// declared length — an out-of-frame field would silently decode as absent
	// on every event, which reads as "signal never changes", not as a bug.
	for lf in eth_layout {
		fr := eth_frames.filter(it.name == lf.frame)
		if fr.len == 0 {
			return error('manifest ethlayout references unknown frame "${lf.frame}"')
		}
		if lf.offset + lf.width > fr[0].length {
			return error('manifest ethlayout ${lf.frame}.${lf.field}: offset ${lf.offset} + width ${lf.width} exceeds the frame length ${fr[0].length}')
		}
	}
	mut m := Manifest{
		handlers:     handlers
		threads:      threads
		frames:       frames
		shell:        shellf
		someip:       sip
		shell_method: shell_method
		eth_frames:   eth_frames
		eth_layout:   eth_layout
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

// eth_frame_by_id resolves a SOME/IP event/method id to its ethframe row.
pub fn (m &Manifest) eth_frame_by_id(id u16) ?EthFrame {
	for f in m.eth_frames {
		if f.id == id {
			return f
		}
	}
	return none
}

// eth_fields returns one eth frame's layout rows in manifest (= wire) order.
pub fn (m &Manifest) eth_fields(frame string) []EthField {
	return m.eth_layout.filter(it.frame == frame)
}
