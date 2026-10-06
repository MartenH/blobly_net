module sysview

import os

// sources.v — what a loaded System was read from. Every file `load` reads (system.toml and each
// node's ecu.toml, a missing one included) is stamped as it is read, so a holder of the model —
// and of anything derived from it — asks ONE question to know whether it is still current.

// Source is one file a model was read from: its path and its stamp when read.
pub struct Source {
pub:
	path  string
	stamp string
}

// stamp is a file's identity now: its modification time and size, or `absent`.
pub fn stamp(path string) Source {
	if !os.exists(path) {
		return Source{path, 'absent'}
	}
	return Source{path, '${os.file_last_mod_unix(path)}:${os.file_size(path)}'}
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
