// lin — the run's LIN rows: a lin.Row per enabled LIN row of the project, each held by
// a counted loop so stop ends it and waits for it. Apart from the CAN rows, which never see one.
module headless

import os
import time
import blobly.lin

// bring_up_lin starts every enabled LIN bus; on a refusal the rows already started are stopped,
// and nothing is left running.
fn (mut r Run) bring_up_lin(o Options) ! {
	mut started := []&lin.Row{}
	for b in r.proj.lin_buses() {
		if !b.enabled {
			continue
		}
		mut row := lin.start_row(lin.spec_of(b, os.dir(r.path)), lin.RowOpts{}) or {
			for mut s in started {
				s.stop()
			}
			return err
		}
		for n in row.notes() {
			o.err(n)
		}
		sim := if b.simulate.len > 0 { ', simulating ${b.simulate.join(', ')}' } else { '' }
		sched := if b.schedule != '' { ', schedule ${b.schedule}' } else { '' }
		o.out('lin ${b.name} (${b.address} @ ${row.baud}): ${b.role}${sim}${sched}')
		started << row
	}
	r.lins = started
	for mut row in started {
		r.counted()
		spawn r.lin_loop(mut row)
	}
}

// lin_loop holds one LIN row until the run stops, then stops it and says what it counted.
fn (mut r Run) lin_loop(mut row lin.Row) {
	defer {
		r.done()
	}
	for r.ctl.running {
		time.sleep(20 * time.millisecond)
	}
	if !row.stop() {
		r.say('lin ${row.spec.name}: its schedule or reader outlived its bound')
	}
	r.report_diag('lin ${row.spec.name}', row.diagnostics())
}

// lin_rows is the run's LIN rows, in project order: what a script's lin.open reaches by name.
pub fn (r &Run) lin_rows() []&lin.Row {
	return r.lins
}
