module rowrule

// A PROJECT ROW'S IDENTITY IS ITS INDEX (#575). A row's name and interface are not one: nothing
// makes the pair unique, and every key built from it was shared by two rows that agree on both —
// the Simulation panel's node tick (unticking a node on one row switched it off on the other),
// its tree's ImGui id, and a DoIP entity's Log lines, which could not say which of two rows had
// failed to bind. The index is what app.chans is built 1:1 from (Chan.proj_idx), and a run's
// rows do not change (#120), so it holds for every worker that reads one. Between runs a row may
// be deleted (restack_sim) or the whole set replaced — a project loaded, the File tab applied —
// and a tick then follows its row by name and interface where only one row has them (rekey_sim).
// A restacked table is keyed against the rows after the deletion, which is what rekey_sim is
// then told it was keyed against.

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

// Rows is a set of project rows as the tick keys see them: each row's name and interface.
pub struct Rows {
pub:
	names  []string
	ifaces []string
}

// pair_count is how many rows have this name and interface.
fn (r Rows) pair_count(name string, iface string) (int, int) {
	mut n := 0
	mut at := -1
	for j in 0 .. r.names.len {
		if j < r.ifaces.len && r.names[j] == name && r.ifaces[j] == iface {
			n++
			at = j
		}
	}
	return n, at
}

// rekey_sim is the tick table once the rows the ticks were keyed against (`was`) become `now`.
// The SAME rows keep every tick, and as many rows as before keep the tick of every row whose name
// and interface did not change (a row edited in Configuration ▸ Buses). A different set — a project loaded, the File tab applied, rows
// deleted, inserted or reordered there — keeps a tick only where one row of `was` and ONE row of
// `now` have its name and interface, moved to that row's index; a tick of rows that share both,
// before or after, is dropped, because
// which of them it belonged to is exactly what a replaced set cannot say, and a dropped tick is
// the default (on), never another row's. A key not spelled by sim_key is kept.
pub fn rekey_sim(ticks map[string]bool, was Rows, now Rows) map[string]bool {
	if was.names == now.names && was.ifaces == now.ifaces {
		return ticks.clone()
	}
	mut out := map[string]bool{}
	mut moved := map[string]bool{}
	for k, v in ticks {
		row, name, iface, node := parse_sim(k) or {
			out[k] = v
			continue
		}
		// as many rows as before: an edit to rows, not to the set, and a row that kept its name
		// and interface is the row it was
		if was.names.len == now.names.len && row < now.names.len && row < now.ifaces.len
			&& now.names[row] == name && now.ifaces[row] == iface {
			out[k] = v
			continue
		}
		n_was, _ := was.pair_count(name, iface)
		n, at := now.pair_count(name, iface)
		if n_was > 1 || n != 1 {
			continue
		}
		if at == row {
			out[k] = v
		} else {
			moved[sim_key(at, name, iface, node)] = v
		}
	}
	// a row's own tick wins over one that moved onto it
	for k, v in moved {
		if k !in out {
			out[k] = v
		}
	}
	return out
}

// parse_sim reads a key sim_key spelled, or none.
fn parse_sim(k string) ?(int, string, string, string) {
	row_s := k.all_before('|')
	if row_s.len == k.len || row_s.len == 0 || !row_s.bytes().all(it.is_digit()) {
		return none
	}
	name, after_name := take_counted(k[row_s.len + 1..])?
	iface, node := take_counted(after_name)?
	return row_s.int(), name, iface, node
}

// take_counted reads `<len>:<text>|` off the front of `rest`: the text, and what follows.
fn take_counted(rest string) ?(string, string) {
	n_s := rest.all_before(':')
	if n_s.len == rest.len || n_s.len == 0 || !n_s.bytes().all(it.is_digit()) {
		return none
	}
	n := n_s.int()
	from := n_s.len + 1
	if from + n >= rest.len || rest[from + n] != `|` {
		return none
	}
	return rest[from..from + n], rest[from + n + 1..]
}

// label is how a Log line names project row `i` of rows named `names`: its name, and its row
// number (counted from 1, as the Configuration panel lists them) when another row has that name
// too — of two such rows, the one whose entity failed to bind could not be told apart. A number
// is added again while the label is still another row's literal name, so no two rows' labels are
// one string.
pub fn label(names []string, i int) string {
	if i < 0 || i >= names.len {
		return ''
	}
	mut l := names[i]
	for {
		mut taken := false
		for j, x in names {
			if j != i && x == l {
				taken = true
				break
			}
		}
		if !taken {
			return l
		}
		l = '${l} (row ${i + 1})'
	}
	return l
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
