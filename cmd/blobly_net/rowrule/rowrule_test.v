module rowrule

// two rows with one name, and a third row
const names = ['CAN1', 'CAN1', 'CAN2']

fn test_twin_rows_tick_their_nodes_apart() {
	assert sim_key(0, 'CAN1', 'vcan0', 'ECU') != sim_key(1, 'CAN1', 'vcan0', 'ECU')
	// the parts cannot spell each other's keys
	assert sim_key(0, 'a|b', 'c', 'd') != sim_key(0, 'a', 'b|c', 'd')
	assert sim_key(0, 'a', 'b:c', 'd') != sim_key(0, 'a', 'b', 'c|d')
	assert sim_key(1, 'x', 'y', 'z') != sim_key(11, 'x', 'y', 'z')
}

fn test_a_deleted_row_takes_its_ticks_and_the_rows_behind_it_keep_theirs() {
	mut t := map[string]bool{}
	t[sim_key(0, 'CAN1', 'vcan0', 'ECU')] = false // row 0's node unticked
	t[sim_key(1, 'CAN1', 'vcan0', 'ECU')] = true
	t[sim_key(2, 'CAN2', 'vcan1', 'GW')] = false
	t['legacy'] = false
	r := restack_sim(t, 0)
	// row 1 is row 0 now, with ITS tick — not the deleted twin's
	assert r[sim_key(0, 'CAN1', 'vcan0', 'ECU')] or { false } == true
	assert sim_key(1, 'CAN1', 'vcan0', 'ECU') !in r
	assert r[sim_key(1, 'CAN2', 'vcan1', 'GW')] or { true } == false
	assert sim_key(2, 'CAN2', 'vcan1', 'GW') !in r
	assert r['legacy'] or { true } == false
	assert r.len == 3
	// deleting a later row leaves the earlier ones alone
	r2 := restack_sim(t, 2)
	assert r2[sim_key(0, 'CAN1', 'vcan0', 'ECU')] or { true } == false
	assert r2[sim_key(1, 'CAN1', 'vcan0', 'ECU')] or { false } == true
	assert r2.len == 3
}

fn test_a_log_line_numbers_a_row_only_when_its_name_is_shared() {
	assert label(names, 0) == 'CAN1 (row 1)'
	assert label(names, 1) == 'CAN1 (row 2)'
	assert label(names, 2) == 'CAN2'
	assert label(names, 3) == ''
}

fn test_a_chip_agrees_with_the_resolved_row() {
	// resolved to row 1: row 1's chip alone, though row 0 has its name and wire
	assert !chip_lit(0, 'vcan0', 1, 'vcan0')
	assert chip_lit(1, 'vcan0', 1, 'vcan0')
	assert !chip_lit(2, 'vcan1', 1, 'vcan0')
	// resolved to no row (`bus: CAN1` names both): both rows on the wire, nobody else
	assert chip_lit(0, 'vcan0', -1, 'vcan0')
	assert chip_lit(1, 'vcan0', -1, 'vcan0')
	assert !chip_lit(2, 'vcan1', -1, 'vcan0')
	// resolved to nothing at all: no chip
	assert !chip_lit(0, 'vcan0', -1, '')
}

fn test_a_tick_follows_its_row_into_a_new_set_of_rows() {
	mut t := map[string]bool{}
	t[sim_key(0, 'CAN1', 'vcan0', 'ECU')] = false
	t[sim_key(2, 'CAN2', 'vcan1', 'GW')] = false
	t['legacy'] = false
	// row 0 deleted in the File tab: CAN2 is row 1 now, and its tick goes with it
	r := rekey_sim(t, ['CAN2'], ['vcan1'])
	assert r[sim_key(0, 'CAN2', 'vcan1', 'GW')] or { true } == false
	assert sim_key(0, 'CAN1', 'vcan0', 'ECU') !in r
	assert r['legacy'] or { true } == false
	assert r.len == 2
	// rows that kept their place keep their ticks
	same := rekey_sim(t, ['CAN1', 'X', 'CAN2'], ['vcan0', 'vcany', 'vcan1'])
	assert same.len == 3
	// a moved tick cannot pick one of two rows sharing a name and an interface: dropped
	two := rekey_sim(t, ['CAN2', 'CAN2'], ['vcan1', 'vcan1'])
	assert two.len == 1
	// nor overwrite the tick a row already has
	mut u := map[string]bool{}
	u[sim_key(0, 'A', 'v', 'N')] = true
	u[sim_key(3, 'A', 'v', 'N')] = false
	k := rekey_sim(u, ['A'], ['v'])
	assert k[sim_key(0, 'A', 'v', 'N')] or { false } == true
	assert k.len == 1
	// names and interfaces holding the separators parse back
	mut w := map[string]bool{}
	w[sim_key(1, 'a|1:b', 'c:|d', 'n|o')] = false
	moved := rekey_sim(w, ['a|1:b'], ['c:|d'])
	assert moved[sim_key(0, 'a|1:b', 'c:|d', 'n|o')] or { true } == false
}
