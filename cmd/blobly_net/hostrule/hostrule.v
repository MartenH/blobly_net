module hostrule

// WHICH RUNTIME ROW IS A DoIP ENTITY'S? (#408)
//
// A DoIP entity's watcher binds while its row is ticked in Buses, marks that row running, and
// files the server it bound in the hosted-entity table. All three are asked of the row the
// watcher was started for, named by its project row index (Chan.proj_idx: app.chans is built
// 1:1 from proj.channels). A row's name and interface are not an identity: nothing makes them
// unique, and two rows sharing both resolved to the first, so a disabled row listed before an
// enabled copy kept the enabled row's entity down and was marked running in its place.
//
// The index holds for a watcher's whole life: it is a run worker, so the rebuild that replaces
// app.chans waits for it to leave first (drainrule), and a run's topology does not change. A
// caller that is not drained (the GUI thread, a script) asks under app.mu, so it reads the rows
// of one project: a row index from another one finds no row, or the row now at that index.

// Row is what a watcher reads of one runtime row.
pub struct Row {
pub:
	proj_idx int  // the project row it was built from
	enabled  bool // its live Buses tick
}

// row_of is the position of the runtime row built from project row `proj_idx`, or none. The rows
// are built 1:1 from the project's, so that position is the index itself.
pub fn row_of(rows []Row, proj_idx int) ?int {
	if proj_idx >= 0 && proj_idx < rows.len && rows[proj_idx].proj_idx == proj_idx {
		return proj_idx
	}
	return none
}

// enabled is project row `proj_idx`'s live tick, or `fallback` (the project's own value) when
// no runtime row was built from it.
pub fn enabled(rows []Row, proj_idx int, fallback bool) bool {
	if i := row_of(rows, proj_idx) {
		return rows[i].enabled
	}
	return fallback
}

// should_host says whether project row `proj_idx`'s entity listens now: its row ticked (a row
// with no runtime row refuses nothing) and its node ticked in Simulation (`node_on`).
pub fn should_host(rows []Row, proj_idx int, node_on bool) bool {
	return enabled(rows, proj_idx, true) && node_on
}

// host_key names project row `proj_idx`'s entry in the hosted-entity table.
pub fn host_key(proj_idx int) string {
	return 'row${proj_idx}'
}
