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
// files are skipped, as both callers already did. A path may be a `.dbc` or an
// `.arxml[#Cluster]` (database.v).
pub fn merge_files(paths []string) Database {
	mut msgs := []Message{}
	mut nodes := []string{}
	mut seen := map[string]bool{}
	mut seen_node := map[string]bool{}
	for p in paths {
		db := load_database(p) or { continue }
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
