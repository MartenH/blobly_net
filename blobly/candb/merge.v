module candb

// merge_files loads and combines several DBC files into one database — the single
// implementation, because the GUI and the headless runner had one each and they disagreed.
//
// The GUI appended everything (keeping exact duplicates, so a message present in two files was
// simulated twice per cycle); the runner deduplicated on the numeric id alone (dropping a
// standard or extended message that legitimately shared a raw id with another). The same
// project therefore produced a different catalogue depending on how it was run, and a
// `protect:` entry naming the variant one of them discarded warned and transmitted the other
// unprotected. Same project, different bus.
//
// The key is id AND frame format, which is what actually identifies a CAN message. Unreadable
// files are skipped, as both callers already did — and SAID, by merge_files_report: a path may
// be a `.dbc` or an `.arxml[#Cluster]` (database.v), and an ARXML that needs a cluster named
// is refused rather than guessed, which a caller that swallows the skip turns back into the
// silent empty database this function was written to end.
pub fn merge_files(paths []string) Database {
	db, _ := merge_files_report(paths)
	return db
}

// merge_files_report is merge_files plus one line per file it could not open and one per
// note the reader made; a front end prints them, a test asserts on them.
pub fn merge_files_report(paths []string) (Database, []string) {
	return merge_files_report_with(paths, open_database)
}

// DatabaseOpener opens one database reference, as open_database does.
pub type DatabaseOpener = fn (ref string) !Loaded

// merge_files_report_with is merge_files_report through `open`: for a caller that opens each
// reference once and must see that one parse everywhere it asks (the headless runner's rate
// check and its row databases).
pub fn merge_files_report_with(paths []string, open DatabaseOpener) (Database, []string) {
	db, _, notes := merge_with_sources(paths, open)
	return db, notes
}

// merge_with_sources is merge_files_report_with that also answers each file's database as it was
// opened, in order: what a lookup judging definitions per file asks (pgn_message_in_catalog).
pub fn merge_with_sources(paths []string, open DatabaseOpener) (Database, []Database, []string) {
	mut sources := []Database{}
	mut notes := []string{}
	for p in paths {
		loaded := open(p) or {
			notes << 'cannot load ${p}: ${err}'
			continue
		}
		notes << loaded.notes
		sources << loaded.db
	}
	return merge_dbs(sources), sources, notes
}

// merge_dbs is the ONE merge of databases already loaded: the first definition of an id AND
// frame format wins, and a node two files declare is listed once. merge_files opens through it,
// and a caller holding loaded databases (the GUI's simulation, replay and verify views, which
// must see the editor's in-memory copy rather than reparse the file) merges through it too.
pub fn merge_dbs(dbs []Database) Database {
	mut msgs := []Message{}
	mut nodes := []string{}
	mut seen := map[string]bool{}
	mut seen_node := map[string]bool{}
	for db in dbs {
		for m in db.messages {
			key := '${m.id}|${m.ext}'
			if key in seen {
				continue
			}
			seen[key] = true
			msgs << m
		}
		for n in db.nodes {
			if n in seen_node {
				continue
			}
			seen_node[n] = true
			nodes << n
		}
	}
	return Database{
		messages: msgs
		nodes:    nodes
	}
}
