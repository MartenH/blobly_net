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
	id        u8
	partition string
	core      int
	fb        string
	handler   string
	period_us u32
}

// name is the FB.handler label used on lanes/legends.
pub fn (h Handler) name() string {
	return if h.fb != '' { '${h.fb}.${h.handler}' } else { h.handler }
}

// Manifest resolves handler_id -> Handler.
pub struct Manifest {
pub:
	handlers []Handler
pub mut:
	by_id map[u8]Handler // built by index()
}

// load_manifest reads + parses a manifest .csv file.
pub fn load_manifest(path string) !Manifest {
	return parse_manifest(os.read_file(path)!)
}

// parse_manifest parses manifest CSV text.
pub fn parse_manifest(text string) !Manifest {
	mut handlers := []Handler{}
	mut seen := map[u8]bool{}
	for raw in text.split_into_lines() {
		line := raw.trim_space()
		if line == '' || line.starts_with('#') {
			continue
		}
		cols := line.split(',').map(it.trim_space())
		if cols.len < 6 {
			return error('manifest row needs 6 columns (id,partition,core,fb,handler,period_us): "${line}"')
		}
		if cols[0].to_lower() == 'id' {
			continue // header row
		}
		// The wire id is one byte and its uniqueness is the manifest's contract — reject a
		// non-numeric / out-of-range / duplicate id rather than let u8() silently wrap it
		// (256 -> 0, -1 -> 255) and mislabel every record of the collided handler.
		if !is_digits(cols[0]) {
			return error('manifest handler id is not a number: "${cols[0]}"')
		}
		idnum := cols[0].int()
		if idnum > 255 {
			return error('manifest handler id out of range 0..255: ${idnum}')
		}
		id := u8(idnum)
		if id in seen {
			return error('manifest has a duplicate handler id: ${id}')
		}
		seen[id] = true
		handlers << Handler{
			id:        id
			partition: cols[1]
			core:      cols[2].int()
			fb:        cols[3]
			handler:   cols[4]
			period_us: u32(cols[5].u32())
		}
	}
	if handlers.len == 0 {
		return error('manifest has no handler rows')
	}
	mut m := Manifest{
		handlers: handlers
	}
	m.index()
	return m
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

// index (re)builds the by_id lookup — call after mutating handlers.
pub fn (mut m Manifest) index() {
	m.by_id = map[u8]Handler{}
	for h in m.handlers {
		m.by_id[h.id] = h
	}
}

// lookup resolves a handler_id; returns none for ids not in the manifest so the caller
// can fall back to a synthetic label (a target/manifest mismatch shouldn't crash a view).
pub fn (m &Manifest) lookup(id u8) ?Handler {
	return m.by_id[id] or { return none }
}

// label resolves a handler_id to a display name, synthesising "handler N" when unknown.
pub fn (m &Manifest) label(id u8) string {
	if h := m.lookup(id) {
		return h.name()
	}
	return 'handler ${id}'
}
