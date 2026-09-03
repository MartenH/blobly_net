// database.v — ONE way to open a database by path (#272): a `.dbc`, or an AUTOSAR `.arxml`
// with an optional `#Cluster` fragment naming the CAN cluster when the file describes several.
//
// The fragment lives in the PATH on purpose: a `.blobnet` `databases:` entry is a list of
// strings, every consumer of that list (the GUI, the headless runner, the startup check, the
// editor's read-only rule) resolves it through here, and a separate `cluster:` key would be
// one more thing for them to disagree about. `project.resolve_asset` splits the fragment off
// before it asks the file system, and puts it back.
module candb

// split_database_ref separates `file.arxml#Cluster` into the file and the cluster name. The
// `#` is a fragment ONLY after an `.arxml` extension — a DBC named `a#b.dbc` keeps its hash.
pub fn split_database_ref(ref string) (string, string) {
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

// load_database opens a `.dbc` or an `.arxml[#Cluster]` as a Database. An ARXML with several
// CAN clusters and no fragment is refused, naming them — a bus chosen silently is a database
// applied to the wrong wire. What the ARXML carries beyond a Database (timing, E2E, SecOC) is
// reachable through `load_arxml_file` for the callers that want it.
pub fn load_database(ref string) !Database {
	file, cluster := split_database_ref(ref)
	if is_arxml_path(file) {
		a := load_arxml_file(file)!
		c := a.cluster(cluster)!
		return c.db
	}
	return load_dbc_file(ref)!
}
