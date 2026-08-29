module logfile

import time

// THE NAME CARRIES THE TIME, sortably and without a colon (Windows cannot have one in a name).
fn test_the_file_name_is_sortable_and_has_no_colon() {
	t := time.Time{
		year:   2026
		month:  8
		day:    29
		hour:   16
		minute: 23
		second: 43
	}
	assert file_name(t) == 'blobly_net-2026-08-29T16-23-43.log'
	assert !file_name(t).contains(':')
	assert is_session_log(file_name(t))
	assert !is_session_log('blobly_net.log')
	assert !is_session_log('notes-2026-08-29T16-23-43.log')
}

// ROTATION KEEPS THE NEWEST N OF OURS and touches nothing else in the directory.
fn test_rotation_removes_the_oldest_of_ours_only() {
	names := ['blobly_net-2026-08-29T16-23-43.log', 'blobly_net-2026-08-27T09-00-00.log',
		'readme.txt', 'blobly_net-2026-08-28T12-00-00.log', 'blobly_net-2026-08-26T08-00-00.log']
	gone := to_delete(names, 2)
	assert gone == ['blobly_net-2026-08-26T08-00-00.log', 'blobly_net-2026-08-27T09-00-00.log']
	assert to_delete(names, 10) == []
	assert to_delete(['readme.txt'], 0) == []
}

// THE HEADER STATES THE FACTS A BUG REPORT NEEDS, first, one per line, `#`-prefixed so a
// reader can tell them from the Log's own lines.
fn test_the_header_states_version_os_project_and_args() {
	h := header(Facts{
		version:  '2026.08.01'
		os_name:  'Windows'
		os_ver:   '11 Pro 10.0.26200'
		arch:     'x86_64'
		cpus:     16
		v_hash:   'c0624b2'
		project:  'C:/bench/test.blobnet'
		args:     ['blobly_net.exe', 'C:/bench/test.blobnet']
		started:  time.Time{ year: 2026, month: 8, day: 29, hour: 16, minute: 23, second: 43 }
		log_path: 'C:/Users/x/AppData/Local/blobly_net/logs/blobly_net-2026-08-29T16-23-43.log'
	})
	lines := h.split_into_lines()
	assert lines.len == 5
	assert lines[0] == '# blobly_net 2026.08.01'
	assert lines[1].starts_with('# started 2026-08-29 16:23:43')
	assert lines[1].ends_with('blobly_net-2026-08-29T16-23-43.log')
	assert lines[2] == '# os Windows 11 Pro 10.0.26200  arch x86_64  cpus 16  v c0624b2'
	assert lines[3] == '# project C:/bench/test.blobnet'
	assert lines[4] == '# args blobly_net.exe C:/bench/test.blobnet'
	for l in lines {
		assert l.starts_with('# ')
	}
}

// THE DIRECTORY IS PER USER AND NAMED FOR US, on either platform.
fn test_the_directory_is_per_user() {
	d := dir()
	assert d.ends_with('logs')
	assert d.contains('blobly_net')
	$if windows {
		assert d.to_lower().contains('appdata')
	} $else {
		assert d.contains('.local/state') || d.contains('/state/')
	}
}
