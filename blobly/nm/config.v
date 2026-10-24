module nm

import blobly.candb
import blobly.project
import blobly.sysview

// default_timeout_ms is the timeout of a configuration that states none (blobly_emb's example
// value).
pub const default_timeout_ms = 300

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
// where the configuration states one, else by its CAN id.
pub struct Declared {
pub:
	name string
	nid  int = -1 // -1: not stated
	id   i64 = -1 // -1: not stated
}

// Config is one wire's NM cluster: the inclusive id range of one frame kind, the timeout past
// which a node or the bus has stopped asking, and who is declared on it.
pub struct Config {
pub:
	lo         u32
	hi         u32
	ext        bool
	timeout_ms int = default_timeout_ms
	repeat_ms  int // 0: not stated
	source     Source
	origin     string // what it was read from, for the panel: `system.toml bus body`
	declared   []Declared
}

// covers: a frame of this id and kind is in the cluster's NM range.
pub fn (c Config) covers(id u32, ext bool) bool {
	return ext == c.ext && id >= c.lo && id <= c.hi
}

// declared_index is the declaration a reporter is: by NID where a declaration states one, else
// by CAN id; -1 when none is.
pub fn (c Config) declared_index(nid u8, id u32) int {
	for i, d in c.declared {
		if d.nid >= 0 && d.nid == int(nid) {
			return i
		}
	}
	for i, d in c.declared {
		if d.nid < 0 && d.id >= 0 && d.id == i64(id) {
			return i
		}
	}
	return -1
}

// key is the configuration's identity: two configurations with one key read a wire alike.
pub fn (c Config) key() string {
	mut s := '${c.lo}|${c.hi}|${c.ext}|${c.timeout_ms}|${c.repeat_ms}|${c.source}|${c.origin}'
	for d in c.declared {
		s += '|${d.name}/${d.nid}/${d.id}'
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
				ext:        extended_range(own.hi)
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
				}
			}
			return Config{
				lo:         b.nm_lo
				hi:         b.nm_hi
				ext:        extended_range(b.nm_hi)
				timeout_ms: if b.nm_timeout_ms > 0 { b.nm_timeout_ms } else { default_timeout_ms }
				repeat_ms:  b.nm_repeat_ms
				source:     .system
				origin:     'system.toml bus ${b.name}'
				declared:   decl
			}
		}
	}
	return none
}

// from_arxml reads the NM-PDU frames of the wire's ARXML clusters: the range spans their ids
// (of the one frame kind they share; a cluster mixing both kinds reads the standard ones), and a
// frame whose sender the file names declares that ECU at that id.
fn from_arxml(dbs []candb.Database) ?Config {
	mut frames := []candb.ArxmlNmFrame{}
	mut origin := ''
	for db in dbs {
		if db.arxml.nm.len > 0 && origin == '' {
			origin = 'ARXML cluster ${db.arxml.name}'
		}
		frames << db.arxml.nm
	}
	if frames.len == 0 {
		return none
	}
	ext := frames.all(it.ext)
	mut lo := u32(0xFFFFFFFF)
	mut hi := u32(0)
	mut decl := []Declared{}
	for f in frames {
		if f.ext != ext {
			continue
		}
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
			}
		}
	}
	return Config{
		lo:       lo
		hi:       hi
		ext:      ext
		source:   .arxml
		origin:   origin
		declared: decl
	}
}
