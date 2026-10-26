module hostrule

// two rows with one name and one endpoint: the disabled one listed first, an enabled copy after
// it. The names are not in Row at all, which is the point: the index is the identity.
const twins = [Row{
	proj_idx: 0
	enabled:  false
}, Row{
	proj_idx: 1
	enabled:  true
}]

fn test_each_watcher_reads_its_own_row() {
	assert !should_host(twins, 0, true)
	assert should_host(twins, 1, true)
	assert row_of(twins, 0)? == 0
	assert row_of(twins, 1)? == 1
}

fn test_the_node_tick_still_decides() {
	assert !should_host(twins, 1, false)
}

fn test_each_row_files_its_own_entity() {
	assert host_key(0) != host_key(1)
}

fn test_a_position_built_from_another_row_is_not_this_one() {
	rows := [Row{
		proj_idx: 1
		enabled:  false
	}]
	assert row_of(rows, 0) == none
	assert enabled(rows, 0, true)
}

fn test_a_row_with_no_runtime_row_falls_back() {
	assert row_of(twins, 7) == none
	assert enabled(twins, 7, false) == false
	assert enabled(twins, 7, true)
	assert should_host(twins, 7, true)
	assert row_of(twins, -1) == none
}
