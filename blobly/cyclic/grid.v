// grid.v — when a periodic source on a wire's loop sends next: a generator's cycle (a headless
// run's and the GUI's, #691) and a background sender's period, each on the grid it has alone
// (sim.next_due), with the fires a generator serves beside its cycle. One copy, which all three
// ask, so the rules for a slot left out, a cycle changed and a fire between two slots are one.
module cyclic

import blobly.sim

// Grid is a periodic source's grid, its wire's loop's alone: the slot its cycle last sent in, the
// period that slot was booked at, when that send ended, whether its cycle sends at once, whether
// it was armed at the last look, and whether a fire waiting goes before its cycle next.
pub struct Grid {
mut:
	slot      u64
	per       u64
	done      u64
	fresh     bool = true
	was       bool
	fire_turn bool
}

// restart sends its cycle at once and on a grid from then: a generator started again.
pub fn (mut g Grid) restart() {
	g.fresh = true
}

// look notes whether its cycle is `armed` (cyclic and able to send): armed since the last look,
// it sends at once and on a grid from then, so the slots it was not armed for are neither sent
// back to back nor counted as left out.
fn (mut g Grid) look(armed bool) {
	if armed && !g.was {
		g.fresh = true
	}
	g.was = armed
}

// due is when it sends next at `now` (ms), its cycle `armed` at `period`, `fire` whether a fire
// waits: at once for a fire or a cycle that sends at once, else its next slot by the period as it
// is now (sim.next_due, from when its last send ended, so a slow write is not followed by a
// catch-up frame); none while not armed and no fire waits.
pub fn (mut g Grid) due(armed bool, period u64, fire bool, now u64) ?u64 {
	g.look(armed)
	if fire || (armed && g.fresh) {
		return now
	}
	if !armed {
		return none
	}
	return sim.next_due(g.slot, period, g.done)
}

// cycle is whether its cycle sends at `now`, and how many of its slots it left out: armed, due
// by `period`, and not a fire's turn (a fire waiting after the cycle's transfer goes first). Its
// slot is booked: `now` for a cycle that sends at once or whose period changed since its last
// slot — the slots of a cycle that did not exist yet are none it left out — else the slot due,
// the ones before it since the last left out (sim.slots_skipped).
pub fn (mut g Grid) cycle(armed bool, period u64, fire bool, now u64) (bool, u64) {
	g.look(armed)
	turn := g.fire_turn && fire
	g.fire_turn = false
	if turn || !armed {
		return false, 0
	}
	if !g.fresh {
		next := sim.next_due(g.slot, period, g.done)
		if now < next {
			return false, 0
		}
		if g.per == period {
			left := sim.slots_skipped(g.slot, period, next)
			g.slot = next
			return true, left
		}
	}
	g.slot = now
	g.per = period
	g.fresh = false
	return true, 0
}

// ended notes a send that ended at `at` (ms): the cycle's (`of_cycle`) grids its next slot from
// then; a fire's leaves the cycle's slots where they were, so a fire between two slots never makes
// the cycle leave one out.
pub fn (mut g Grid) ended(of_cycle bool, at u64) {
	if of_cycle {
		g.done = at
	}
}

// pumped notes a pass that drove a transfer: `cycle_ended` when it was the cycle's and it ended,
// so a fire waiting goes next and a cycle shorter than its transfer cannot starve the fires.
pub fn (mut g Grid) pumped(cycle_ended bool) {
	g.fire_turn = cycle_ended
}
