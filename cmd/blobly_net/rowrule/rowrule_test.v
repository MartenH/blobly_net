module rowrule

// two rows with one name and one interface, and a third row
const names = ['CAN1', 'CAN1', 'CAN2']
const ifaces = ['vcan0', 'vcan0', 'vcan1']

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

fn test_a_twin_is_the_other_row_with_both_name_and_interface() {
	assert twin_of(names, ifaces, 0)? == 1
	assert twin_of(names, ifaces, 1)? == 0
	assert twin_of(names, ifaces, 2) == none
	// one name on two wires is not a twin: the interface tells those apart
	assert twin_of(['A', 'A'], ['vcan0', 'vcan1'], 0) == none
}
