module tickrule

// WHAT THE BUSES TICK SHOWS (#287)
//
// A row's `enabled` has two copies: the project's (what Save writes, what the next Start opens)
// and the run's. They differ in one case only: a reader whose adapter stopped answering retires
// every row on its wire for the rest of that run, in the run's copy alone, and the next Start
// restores it from the project. The tick is a project edit, so it shows the project's bit, and
// the retirement is said beside it.

// Tick is what a row's enable tick draws: the box, and the line beside it ('' for none).
pub struct Tick {
pub:
	ticked bool
	note   string
}

// tick is a row's tick from the project's bit, the run's bit and whether a run is going.
pub fn tick(model bool, runtime bool, running bool) Tick {
	if model && !runtime {
		return Tick{
			ticked: true
			note:   if running {
				'retired for this run: its adapter stopped answering'
			} else {
				'retired in the last run: its adapter stopped answering; Start opens it again'
			}
		}
	}
	return Tick{
		ticked: model
	}
}
