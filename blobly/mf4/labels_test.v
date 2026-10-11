module mf4

const labels_demo_path = @VMODROOT + '/samples/demo.mf4'

// A label exists in the arena only if a row carries it. The group label was interned for every
// channel group once — signal and error-frame groups included — and a one-bus file read as
// four buses, which turned the GUI's single-bus verification fallback off for every import.
fn test_labels_are_only_the_buses_rows_carry() {
	rec := load_recording(labels_demo_path) or {
		eprintln('samples/demo.mf4 not found: ${err}')
		return
	}
	mut used := map[string]bool{}
	for i in 0 .. rec.log.len() {
		used[rec.log.iface(i)] = true
	}
	assert rec.log.labels.len == used.len, 'labels ${rec.log.labels} but rows carry ${used.keys()}'
	assert rec.log.labels.len == rec.buses.len
	for b in rec.buses {
		assert rec.log.index_of(b.iface) != none, b.iface
	}
}
