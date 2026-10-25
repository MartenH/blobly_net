module tickrule

// WHAT THE BUSES TICK SHOWS (#287)
//
// A row's `enabled` has two copies: the project's (what Save writes, what the next Start opens)
// and the run's. A reader whose adapter stopped answering RETIRES every row on its wire for the
// rest of that run, in the run's copy alone, and the next Start restores it from the project. The
// tick is a project edit, so it shows the project's bit, and a retirement is said beside it — from
// its own flag, since the two copies also differ while a Configuration edit waits to be applied.

// Tick is what a row's enable tick draws: the box, and the line beside it ('' for none).
pub struct Tick {
pub:
	ticked bool
	note   string
}

// tick is a row's tick from the project's bit, whether the run retired the row, and whether a
// run is going.
pub fn tick(model bool, retired bool, running bool) Tick {
	if model && retired {
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
