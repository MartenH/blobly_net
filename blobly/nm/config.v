module nm

import blobly.candb
import blobly.project
import blobly.sysview

// default_timeout_ms is the timeout of a system model or project that states none
// (blobly_emb's example value).
pub const default_timeout_ms = 300

// arxml_timeout_ms is the timeout an ARXML-read cluster is given: the system description does not
// carry CanNm's network timeout, and AUTOSAR clusters commonly run a 2 s timeout over a cycle up
// to a second — 300 ms would read every gap between two frames as the network asleep.
pub const arxml_timeout_ms = 2000

// Source is where a wire's NM configuration came from.
pub enum Source {
	system  // the system model (system.toml): range, timeout and node names
	arxml   // the wire's ARXML NM-PDU frames: their ids, and their senders' names
	project // the channel's own `nm:` setting: a range and a timeout, no names
}

pub fn (s Source) str() string {
	return match s {
		.system { 'system.toml' }
		.arxml { 'ARXML' }
		.project { 'project' }
	}
}

// Declared is a node the configuration says is on the cluster, matched to a reporter by its NID
// and its CAN id, each where the configuration states one.
pub struct Declared {
pub:
	name string
	nid  int = -1 // -1: not stated
	id   i64 = -1 // -1: not stated
	ext  bool // the kind of `id`
}

// Config is one wire's NM cluster: which frames are NM — the inclusive id range of one frame
// kind, or the exact frames an ARXML names — the timeout past which a node or the bus has
// stopped asking, and who is declared on it.
pub struct Config {
pub:
	lo  u32
	hi  u32
	ext bool
	// the exact NM frames (frame_key) and the byte their PDU starts at in the frame; when given,
	// these are the cluster's frames and lo/hi only bound them
	frames          map[u64]int
	timeout_ms      int = default_timeout_ms
	timeout_default bool // the configuration states no timeout; timeout_ms is this module's
	source          Source
	origin          string // what it was read from, for the panel: `system.toml bus body`
	declared        []Declared
}

// frame_key is one frame's identity in Config.frames: the id and its kind.
pub fn frame_key(id u32, ext bool) u64 {
	return (if ext { u64(1) << 32 } else { u64(0) }) | u64(id)
}

// covers: a frame of this id and kind is one of the cluster's NM frames.
pub fn (c Config) covers(id u32, ext bool) bool {
	if c.frames.len > 0 {
		return frame_key(id, ext) in c.frames
	}
	return ext == c.ext && id >= c.lo && id <= c.hi
}

// pdu_byte is where the NM PDU starts in a frame of this id and kind.
pub fn (c Config) pdu_byte(id u32, ext bool) int {
	return c.frames[frame_key(id, ext)] or { 0 }
}

// declared_index is the declaration a reporter is: one whose NID and CAN id, each where it states
// one, are the reporter's; -1 when none is. A node announcing on another node's id, or with
// another node's NID, is unknown rather than named.
pub fn (c Config) declared_index(nid u8, id u32, ext bool) int {
	for i, d in c.declared {
		if (d.nid < 0 || d.nid == int(nid)) && (d.id < 0 || (d.id == i64(id) && d.ext == ext)) {
			return i
		}
	}
	return -1
}

// describe names the cluster's NM frames: `NM ids 0x500..0x53F`, or the ARXML's frames one by one.
pub fn (c Config) describe() string {
	if c.frames.len > 0 {
		mut keys := c.frames.keys()
		keys.sort()
		mut parts := []string{}
		for k in keys {
			kind := if k >> 32 != 0 { ' (29-bit)' } else { '' }
			at := c.frames[k] or { 0 }
			off := if at > 0 { ' at byte ${at}' } else { '' }
			parts << '0x${u32(k & 0xFFFFFFFF):X}${kind}${off}'
		}
		return 'NM frames ${parts.join(', ')}'
	}
	kind := if c.ext { ' (29-bit)' } else { '' }
	return 'NM ids 0x${c.lo:X}..0x${c.hi:X}${kind}'
}

// key is the configuration's identity: two configurations with one key read a wire alike.
pub fn (c Config) key() string {
	mut s := '${c.lo}|${c.hi}|${c.ext}|${c.timeout_ms}|${c.source}|${c.origin}|${c.describe()}'
	for d in c.declared {
		s += '|${d.name}/${d.nid}/${d.id}/${d.ext}'
	}
	return s
}

// extended_range is the frame kind a configured range is read as: ids above 0x7FF are 29-bit,
// the rule sysview's id allocation uses.
fn extended_range(hi u32) bool {
	return hi > 0x7FF
}

// configure is the ONE rule for a wire's NM configuration. `rows` are the CAN rows on the wire,
// `dbs` the databases loaded for it, `sys` the system model (empty when there is none). First
// the system model, through a bus with an NM range named like one of the rows; else the
// databases' ARXML NM-PDU frames; else the first row's own `nm:`. With none, the wire has no NM
// reading: nothing guesses that a frame is NM.
pub fn configure(sys &sysview.System, rows []project.Channel, dbs []candb.Database) ?Config {
	if c := from_system(sys, rows) {
		return c
	}
	if c := from_arxml(dbs) {
		return c
	}
	for r in rows {
		if own := r.nm {
			return Config{
				lo:         own.lo
				hi:         own.hi
				ext:        own.ext || extended_range(own.hi)
				timeout_ms: own.timeout_ms
				source:     .project
				origin:     'channel ${r.name}'
			}
		}
	}
	return none
}

// from_system reads the cluster of the system bus a row is named after: its range and timeout,
// and every node on that bus with an NM offset, whose NID the offset is (blobly_emb announces
// node `n` on `base + n`).
fn from_system(sys &sysview.System, rows []project.Channel) ?Config {
	for r in rows {
		for b in sys.buses {
			if b.name != r.name || !b.is_can() || b.nm_lo == 0 || b.nm_hi < b.nm_lo {
				continue
			}
			mut decl := []Declared{}
			for n in sys.nodes {
				if b.name !in n.buses || n.nm == 0 || n.nm > 0xFF {
					continue
				}
				decl << Declared{
					name: n.name
					nid:  int(n.nm)
					id:   i64(b.nm_lo) + i64(n.nm)
					ext:  extended_range(b.nm_hi)
				}
			}
			return Config{
				lo:              b.nm_lo
				hi:              b.nm_hi
				ext:             extended_range(b.nm_hi)
				timeout_ms:      if b.nm_timeout_ms > 0 {
					b.nm_timeout_ms
				} else {
					default_timeout_ms
				}
				timeout_default: b.nm_timeout_ms <= 0
				source:          .system
				origin:          'system.toml bus ${b.name}'
				declared:        decl
			}
		}
	}
	return none
}

// from_arxml reads the NM-PDU frames of the wire's ARXML clusters: those frames, of either kind,
// are the cluster's NM frames — exactly those, never the ids between them — each read from the
// byte its PDU starts at; a frame whose sender the file names declares that ECU on it. A file
// attached through two rows of one wire is read once.
fn from_arxml(dbs []candb.Database) ?Config {
	mut frames := map[u64]int{}
	mut decl := []Declared{}
	mut origin := ''
	mut lo := u32(0xFFFFFFFF)
	mut hi := u32(0)
	for db in dbs {
		for f in db.arxml.nm {
			k := frame_key(f.id, f.ext)
			if k in frames {
				continue
			}
			if origin == '' {
				origin = 'ARXML cluster ${db.arxml.name}'
			}
			frames[k] = f.byte
			if f.id < lo {
				lo = f.id
			}
			if f.id > hi {
				hi = f.id
			}
			if f.ecu != '' {
				decl << Declared{
					name: f.ecu
					id:   i64(f.id)
					ext:  f.ext
				}
			}
		}
	}
	if frames.len == 0 {
		return none
	}
	return Config{
		lo:              lo
		hi:              hi
		ext:             frames.keys().all(it >> 32 != 0)
		frames:          frames
		timeout_ms:      arxml_timeout_ms
		timeout_default: true
		source:          .arxml
		origin:          origin
		declared:        decl
	}
}
