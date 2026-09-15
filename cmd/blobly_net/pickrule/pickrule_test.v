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
