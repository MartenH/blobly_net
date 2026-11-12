module cyclic

// a cycle sends at once when armed, then on its slots, a late send leaving the slots it covered
// out and counting them
fn test_a_cycle_sends_on_its_slots_and_counts_the_ones_it_left_out() {
	mut g := Grid{}
	assert g.due(true, 10, false, 100)? == 100
	sends0, left0 := g.cycle(true, 10, false, 100)
	assert sends0 && left0 == 0
	g.ended(true, 100)
	assert g.due(true, 10, false, 101)? == 110
	sends1, _ := g.cycle(true, 10, false, 105)
	assert !sends1, 'not due before its slot'
	sends2, left2 := g.cycle(true, 10, false, 110)
	assert sends2 && left2 == 0
	// its write took 25 ms: the next slot is the first after it ended, two left out
	g.ended(true, 135)
	assert g.due(true, 10, false, 135)? == 140
	sends3, left3 := g.cycle(true, 10, false, 140)
	assert sends3 && left3 == 2
}

// a fire between two slots leaves the cycle's slots where they were
fn test_a_fire_never_makes_the_cycle_leave_a_slot_out() {
	mut g := Grid{}
	g.cycle(true, 10, false, 0)
	g.ended(true, 0)
	// a fire sent at 9.6 ms that returned at 10 ms
	g.ended(false, 10)
	sends, left := g.cycle(true, 10, false, 10)
	assert sends && left == 0, 'the slot at 10 is sent, not left out'
}

// a period changed since the last slot runs from that slot by the new period, and the slots of
// a cycle that did not exist yet are none it left out
fn test_a_changed_period_counts_no_slot_of_a_cycle_that_did_not_exist() {
	mut g := Grid{}
	g.cycle(true, 60, false, 0)
	g.ended(true, 0)
	// shortened to 10 at 50: due at once (its next slot by 10 is past), nothing left out
	assert g.due(true, 10, false, 50)? == 10
	sends, left := g.cycle(true, 10, false, 50)
	assert sends && left == 0
	g.ended(true, 50)
	assert g.due(true, 10, false, 50)? == 60
	sends2, left2 := g.cycle(true, 10, false, 60)
	assert sends2 && left2 == 0
	// lengthened to 1000: waits for its slot by the new period
	g.ended(true, 60)
	sends3, _ := g.cycle(true, 1000, false, 70)
	assert !sends3
	sends4, left4 := g.cycle(true, 1000, false, 1060)
	assert sends4 && left4 == 0
}

// armed again after it was not, a cycle sends at once and counts nothing for the time it was not
fn test_a_cycle_armed_again_starts_from_now() {
	mut g := Grid{}
	g.cycle(true, 10, false, 0)
	g.ended(true, 0)
	assert g.due(false, 10, false, 5) == none
	g.cycle(false, 10, false, 5)
	sends, left := g.cycle(true, 10, false, 500)
	assert sends && left == 0
	assert g.due(true, 10, false, 500)? == 510
}

// a fire is due at once, armed or not
fn test_a_fire_is_due_at_once() {
	mut g := Grid{}
	assert g.due(false, 0, true, 7)? == 7
	g.cycle(true, 10, false, 0)
	g.ended(true, 0)
	assert g.due(true, 10, true, 3)? == 3
}

// once the cycle's transfer ended, a fire waiting goes before the cycle, once
fn test_a_fire_waiting_goes_first_after_the_cycles_transfer() {
	mut g := Grid{}
	g.cycle(true, 10, false, 0)
	g.ended(true, 0)
	g.pumped(true)
	sends, _ := g.cycle(true, 10, true, 20)
	assert !sends, 'the fire goes first'
	sends2, _ := g.cycle(true, 10, false, 20)
	assert sends2, 'then the cycle'
	// with no fire waiting the cycle is not held back
	g.ended(true, 20)
	g.pumped(true)
	sends3, _ := g.cycle(true, 10, false, 30)
	assert sends3
}

// restarted, a cycle sends at once and on a grid from then
fn test_a_restarted_cycle_sends_at_once() {
	mut g := Grid{}
	g.cycle(true, 100, false, 0)
	g.ended(true, 0)
	g.restart()
	assert g.due(true, 100, false, 30)? == 30
	sends, left := g.cycle(true, 100, false, 30)
	assert sends && left == 0
	g.ended(true, 30)
	assert g.due(true, 100, false, 30)? == 130
}
