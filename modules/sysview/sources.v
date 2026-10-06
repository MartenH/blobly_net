module sysview

import os
import candb

// sources.v — what a loaded System was read from. Every file `load` reads (system.toml and each
// node's ecu.toml, a missing one included) is stamped from its content as it is read, so a holder of the model —
// and of anything derived from it — asks ONE question to know whether it is still current.

// Source is one file a model was read from: its path and its stamp when read.
pub struct Source {
pub:
	path  string
	stamp string
}

// read_source reads a file the model is built from, and stamps it from the very bytes it returns
// (candb.content_key: real path and SHA-256), so a change between reading and stamping cannot go
// unseen. A file that cannot be read stamps `absent`, and its appearing is a change.
pub fn read_source(path string) (Source, ?string) {
	text := os.read_file(path) or { return Source{path, 'absent'}, none }
	key, sha := candb.content_key(path, text)
	return Source{path, '${key}#${sha}'}, text
}

// stamp is a file's identity now, as read_source would stamp it.
pub fn stamp(path string) Source {
	s, _ := read_source(path)
	return s
}

// current: every file the model was read from is as it was read. A model whose answer is false
// is reloaded, and everything derived from it rebuilt.
pub fn (sys &System) current() bool {
	return sys.sources.len > 0 && sys.sources.all(stamp(it.path).stamp == it.stamp)
}

// identity names this model and what it was read from, for a cache keyed on it.
pub fn (sys &System) identity() string {
	return sys.sources.map('${it.path}@${it.stamp}').join('|')
}
