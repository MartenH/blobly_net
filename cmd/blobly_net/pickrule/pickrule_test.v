module pickrule

// #270 items 4 and 5, as a table.

fn test_go_enters_a_folder_and_accepts_a_file() {
	assert activate(.dir, false) == .enter
	assert activate(.file, false) == .accept
}

fn test_in_save_mode_a_file_is_named_never_accepted_without_the_save_button() {
	assert activate(.dir, true) == .enter
	assert activate(.file, true) == .select
}

fn test_a_lone_click_enters_a_folder_and_selects_a_file() {
	for save in [false, true] {
		mut b := Burst{}
		b.press(1)
		assert b.click(.dir, save) == .enter
		assert b.click(.file, save) == .select
	}
}

// #270's hand: the first click of the double entered a folder, and the second lands on a row
// of the folder it entered. Whatever that row is, in either mode, nothing happens.
fn test_the_second_click_of_a_double_whose_first_entered_a_folder_is_ignored() {
	for save in [false, true] {
		mut b := Burst{}
		b.press(1)
		assert b.click(.dir, save) == .enter
		b.listing_replaced()
		b.press(0) // frames with no press change nothing
		b.press(2)
		assert b.click(.dir, save) == .ignore
		assert b.click(.file, save) == .ignore
		b.press(3) // a third click of the same burst is no better aimed
		assert b.click(.file, save) == .ignore
	}
}

fn test_a_double_click_that_began_on_a_file_is_what_enter_and_open_do() {
	mut b := Burst{}
	b.press(1)
	assert b.click(.file, false) == .select
	b.press(2)
	assert b.click(.file, false) == .accept
	assert b.click(.dir, false) == .enter
	mut s := Burst{}
	s.press(1)
	s.press(2)
	assert s.click(.file, true) == .select // save mode: never an unconfirmed overwrite
}

// The listing can be replaced by something that is not a row — the drive dropdown, `.. up`, a
// typed path, the menu that opened the picker under the pointer (which the picker never saw
// press) — and the second click of that burst is just as unaimed.
fn test_a_listing_replaced_by_any_control_protects_the_second_click() {
	mut b := Burst{}
	b.press(1)
	b.listing_replaced()
	b.press(2)
	assert b.click(.file, false) == .ignore
	mut m := Burst{} // opened from the menu: the first press was never seen
	m.listing_replaced()
	m.press(2)
	assert m.click(.dir, false) == .ignore
}

// The next burst starts clean: what an earlier one replaced is not its doing.
fn test_a_new_burst_forgets_the_last_replacement() {
	mut b := Burst{}
	b.press(1)
	b.listing_replaced()
	b.press(2)
	assert b.click(.file, false) == .ignore
	b.press(1)
	assert b.click(.dir, false) == .enter
	assert b.click(.file, false) == .select
	b.press(2)
	assert b.click(.file, false) == .accept
}

fn test_a_windows_drive_root_is_spelled_three_ways_and_only_those() {
	for r in ['C:', 'C:\\', 'C:/', 'd:', 'd:\\', 'Z:/'] {
		assert is_drive_root(r), r
	}
	for x in ['', 'C', 'C:\\x', 'C:\\\\', '1:\\', '\\\\srv\\share', '/', 'CC:'] {
		assert !is_drive_root(x), x
	}
}

fn test_up_from_a_windows_folder_reaches_the_root_then_the_drives() {
	assert parent('D:\\ems2\\blobly_net', true) == 'D:\\ems2'
	assert parent('D:\\ems2\\blobly_net\\', true) == 'D:\\ems2' // trailing separator ignored
	assert parent('D:/ems2/blobly_net', true) == 'D:/ems2'
	// directly under the root: the root spelled with its separator, never the bare `D:`
	assert parent('D:\\ems2', true) == 'D:\\'
	assert parent('D:/ems2', true) == 'D:\\'
	// the root itself, in every spelling, goes to the drives view
	assert parent('D:\\', true) == drives
	assert parent('D:', true) == drives
	assert parent('D:/', true) == drives
	// and the drives view has no parent
	assert parent(drives, true) == drives
}

fn test_up_on_linux_stops_at_the_root_and_never_reaches_a_drives_view() {
	assert parent('/home/me/proj', false) == '/home/me'
	assert parent('/home/me/proj/', false) == '/home/me'
	assert parent('/home', false) == '/'
	assert parent('/', false) == '/'
	assert parent('/', false) != drives
}

fn test_a_bare_relative_name_is_its_own_parent() {
	assert parent('projects', false) == 'projects'
	assert parent('projects', true) == 'projects'
}

fn test_a_unc_share_root_is_its_own_parent() {
	assert parent('\\\\srv\\share\\x\\y', true) == '\\\\srv\\share\\x'
	assert parent('\\\\srv\\share\\x', true) == '\\\\srv\\share'
	assert parent('\\\\srv\\share', true) == '\\\\srv\\share'
	assert parent('//srv/share/', true) == '//srv/share'
	assert parent('\\\\srv', true) == '\\\\srv'
	for r in ['\\\\srv\\share', '//srv/share', '\\\\srv'] {
		assert is_unc_root(r), r
	}
	for x in ['\\\\srv\\share\\x', '\\\\\\share', '\\\\srv\\\\x', '\\srv\\share', 'C:\\', '\\\\'] {
		assert !is_unc_root(x), x
	}
}
