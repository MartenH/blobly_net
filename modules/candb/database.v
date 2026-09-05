// database.v — ONE way to open a database by path (#272): a `.dbc`, or an AUTOSAR `.arxml`
// with an optional `#Cluster` fragment naming the CAN cluster when the file describes several.
//
// The fragment lives in the PATH on purpose: a `.blobnet` `databases:` entry is a list of
// strings, every consumer of that list (the GUI, the headless runner, the startup check, the
// editor's read-only rule) resolves it through here, and a separate `cluster:` key would be
// one more thing for them to disagree about. `project.resolve_asset` splits the fragment off
// before it asks the file system and puts it back; `canonical_database_ref` is the ONE way to
// turn a reference into the key the GUI stores loaded databases under.
module candb

import os

// split_database_ref separates `file.arxml#Cluster` into the file and the cluster name. The
// `#` is a fragment ONLY after an `.arxml` extension — a DBC named `a#b.dbc` keeps its hash.
pub fn split_database_ref(ref string) (string, string) {
	if ref.to_lower().ends_with('.dbc') || ref.to_lower().ends_with('.arxml') {
		// the WHOLE reference names a file: `archive.arxml#body.dbc` is one DBC with a hash in
		// its name, `archive.arxml#copy.arxml` one ARXML — not an ARXML with a `body.dbc` or
		// `copy.arxml` cluster (codex on #273 rounds 26 and 29). A cluster fragment never ends
		// in a database extension
		return ref, ''
	}
	i := ref.last_index('#') or { return ref, '' }
	file := ref[..i]
	if !is_arxml_path(file) {
		return ref, ''
	}
	return file, ref[i + 1..]
}

// is_arxml_path reports whether a path (without fragment) names an ARXML file.
pub fn is_arxml_path(path string) bool {
	return path.to_lower().ends_with('.arxml')
}

// is_arxml_ref reports whether a database reference names an ARXML, fragment or not.
pub fn is_arxml_ref(ref string) bool {
	file, _ := split_database_ref(ref)
	return is_arxml_path(file)
}

// canonical_database_ref is the identity of a database reference: the FILE's real path (two
// spellings of one file are one database) with the cluster fragment carried along. Every
// place that stores or looks up a loaded database by path goes through this — a real_path
// over the whole reference fails on the fragment and returns its input, so a lookup keyed
// that way misses whenever the spelling was not canonical already.
pub fn canonical_database_ref(ref string) string {
	file, cluster := split_database_ref(ref)
	frag := if cluster != '' { '#' + cluster } else { '' }
	return os.real_path(file) + frag
}

// Loaded is a database plus what the reader had to say about it: for an ARXML the honesty
// report (dangling references, ignored element kinds, partial reads), one line each, prefixed
// with the file; for a DBC nothing. Every front end prints these — a note only the export
// tool prints is a note nobody on the bench sees.
pub struct Loaded {
pub:
	db    Database
	notes []string
}

// open_database opens a `.dbc` or an `.arxml[#Cluster]`. An ARXML with several CAN clusters
// and no fragment is refused, naming them — a bus chosen silently is a database applied to
// the wrong wire. What the ARXML carries beyond a Database (timing, E2E, SecOC) is reachable
// through `load_arxml_file` for the callers that want it.
pub fn open_database(ref string) !Loaded {
	file, cluster := split_database_ref(ref)
	if is_arxml_path(file) {
		a := load_arxml_file(file)!
		c := a.cluster(cluster)!
		base := os.base(file)
		return Loaded{
			db:    c.db
			notes: a.report.lines().map('${base}: ${it}')
		}
	}
	return Loaded{
		db: load_dbc_file(ref)!
	}
}

// load_database is open_database without the notes, for callers that report nothing.
pub fn load_database(ref string) !Database {
	return open_database(ref)!.db
}
