module candb

import os

// The GUI and the headless runner used to merge differently: one kept exact duplicates, the
// other dropped a standard/extended pair sharing a raw id. Both are pinned here so the single
// implementation cannot drift back.
fn test_merge_files_keeps_both_frame_formats_and_drops_exact_duplicates() {
	dir := os.join_path(os.temp_dir(), 'candb_merge_test')
	os.mkdir_all(dir) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	a := os.join_path(dir, 'a.dbc')
	b := os.join_path(dir, 'b.dbc')
	// 0x100 standard in a.dbc; 0x100 EXTENDED (id | 0x80000000) plus a repeat of the standard
	// one in b.dbc
	os.write_file(a, 'BU_: N1\n\nBO_ 256 Std: 8 N1\n SG_ S1 : 0|8@1+ (1,0) [0|0] "" N1\n') or {
		panic(err)
	}
	os.write_file(b, 'BU_: N1\n\nBO_ 2147483904 Ext: 8 N1\n SG_ S2 : 0|8@1+ (1,0) [0|0] "" N1\n\nBO_ 256 Std: 8 N1\n SG_ S1 : 0|8@1+ (1,0) [0|0] "" N1\n') or {
		panic(err)
	}
	db := merge_files([a, b])
	mut at_100 := 0
	for m in db.messages {
		if m.id == 0x100 {
			at_100++
		}
	}
	assert at_100 == 2, 'standard and extended 0x100 must both survive, got ${at_100}'
	assert db.messages.len == 2, 'the exact duplicate must be dropped, got ${db.messages.len}'
	assert db.nodes == ['N1'], 'node lists must dedupe too, got ${db.nodes}'
}
