module rowrule

// A PROJECT ROW'S IDENTITY IS ITS INDEX (#575). A row's name and interface are not one: nothing
// makes the pair unique, and every key built from it was shared by two rows that agree on both —
// the Simulation panel's node tick (unticking a node on one row switched it off on the other),
// its tree's ImGui id, and a DoIP entity's Log lines, which could not say which of two rows had
// failed to bind. The index is what app.chans is built 1:1 from (Chan.proj_idx), and a run's
// rows do not change (#120), so it holds for every worker that reads one. Rows are only appended
// or deleted, never reordered; a deletion restacks what is keyed by index (restack_sim).

// sim_key names one simulated ECU's tick: project row `row`, and the node by name. The row's
// name and interface are kept in the key, so a tick does not follow a row renamed or
// re-addressed into something else. Length-prefixed, so no name, interface or node can spell
// another's key.
pub fn sim_key(row int, name string, iface string, node string) string {
	return '${row}|${sim_tail(name, iface, node)}'
}

fn sim_tail(name string, iface string, node string) string {
	return '${name.len}:${name}|${iface.len}:${iface}|${node}'
}

// restack_sim is the tick table after project row `removed` is deleted: that row's ticks go, and
// every later row's move down one with it. Without it the row that moved into the deleted row's
// place took the deleted row's ticks when the two shared a name, an interface and a node — the
// twins this key exists to tell apart. A key not spelled by sim_key is kept as it is.
pub fn restack_sim(ticks map[string]bool, removed int) map[string]bool {
	mut out := map[string]bool{}
	for k, v in ticks {
		row_s := k.all_before('|')
		if row_s.len == k.len || row_s.len == 0 || !row_s.bytes().all(it.is_digit()) {
			out[k] = v
			continue
		}
		row := row_s.int()
		tail := k[row_s.len + 1..]
		if row == removed {
			continue
		}
		out[if row > removed { '${row - 1}|${tail}' } else { k }] = v
	}
	return out
}

// label is how a Log line names project row `i` of rows named `names`: its name, and its row
// number (counted from 1, as the Configuration panel lists them) when another row has that name
// too — of two such rows, the one whose entity failed to bind could not be told apart.
pub fn label(names []string, i int) string {
	if i < 0 || i >= names.len {
		return ''
	}
	mut n := 0
	for x in names {
		if x == names[i] {
			n++
		}
	}
	return if n > 1 { '${names[i]} (row ${i + 1})' } else { names[i] }
}

// chip_lit says whether a generator's bus chip for row `ci` (on `iface`) is lit. A generator
// that resolved to ONE row (`owner` >= 0) lights that row's chip alone, whatever other rows share
// its name and interface. One that resolved to no row — a `bus:` several rows answer to, or a
// wire no row owns — lights every row on the wire it transmits on (`target`), because that is
// all the file says: the chips then agree with the verdict instead of picking one of them.
pub fn chip_lit(ci int, iface string, owner int, target string) bool {
	if owner >= 0 {
		return ci == owner
	}
	return target != '' && iface == target
}
