module project

import os

// A project kept OUTSIDE the repository with relative `databases:` entries: the headless runner
// opened them as written after runtests.sh had cd'd to the repo root, so the load failed, the
// database came back empty, and the simulation transmitted nothing with no error anywhere.
fn test_resolve_asset_uses_the_projects_own_directory() {
	dir := os.join_path(os.temp_dir(), 'blobly_asset_test', 'proj')
	os.mkdir_all(os.join_path(dir, 'dbc')) or {}
	defer {
		os.rmdir_all(os.join_path(os.temp_dir(), 'blobly_asset_test')) or {}
	}
	rel := os.join_path('dbc', 'x.dbc')
	os.write_file(os.join_path(dir, rel), 'BU_: N1\n') or { panic(err) }

	got := resolve_asset(dir, rel)
	assert os.exists(got), 'must resolve against the project dir, got ${got}'
	assert got == os.join_path(dir, rel)

	// an absolute path is returned untouched
	abs := os.join_path(dir, rel)
	assert resolve_asset('/elsewhere', abs) == abs

	// a path that does not exist beside the project is left alone, so repo-root-relative
	// projects keep working
	assert resolve_asset(dir, 'dbc/missing.dbc') == 'dbc/missing.dbc'
	assert resolve_asset(dir, '') == ''
}

// The vendor backends default to 500 kbit/s when the interface carries no rate, so a channel
// configured for anything else produced no traffic headlessly while working in the GUI.
fn test_iface_with_bitrate_applies_only_to_vendor_adapters() {
	pcan := Channel{ iface: 'pcan:PCAN_USBBUS1', adapter: 'pcan', bitrate: 250000 }
	assert pcan.iface_with_bitrate() == 'pcan:PCAN_USBBUS1@250000'

	kv := Channel{ iface: 'kvaser:0', adapter: 'kvaser', bitrate: 1000000 }
	assert kv.iface_with_bitrate() == 'kvaser:0@1000000'

	// in-process and SocketCAN take no rate in the string — appending one would break the open
	inproc := Channel{ iface: 'inproc:CAN1', adapter: 'virtual', bitrate: 500000 }
	assert inproc.iface_with_bitrate() == 'inproc:CAN1'

	sc := Channel{ iface: 'can0', adapter: 'socketcan', bitrate: 250000 }
	assert sc.iface_with_bitrate() == 'can0'

	// and an unset rate must not append @0
	none_rate := Channel{ iface: 'pcan:PCAN_USBBUS1', adapter: 'pcan', bitrate: 0 }
	assert none_rate.iface_with_bitrate() == 'pcan:PCAN_USBBUS1'
}

fn test_resolve_asset_keeps_an_arxml_cluster_fragment() {
	dir := os.join_path(os.temp_dir(), 'project_asset_frag_test')
	os.mkdir_all(os.join_path(dir, 'db')) or {}
	defer {
		os.rmdir_all(dir) or {}
	}
	os.write_file(os.join_path(dir, 'db', 'net.arxml'), '<AUTOSAR/>') or { panic(err) }
	// the file system is asked about the FILE; the fragment rides along on the answer
	assert resolve_asset(dir, 'db/net.arxml#Body') == os.join_path(dir, 'db', 'net.arxml') + '#Body'
	assert resolve_asset(dir, 'db/net.arxml') == os.join_path(dir, 'db', 'net.arxml')
	// a missing file comes back as written, fragment included, so the error names it
	assert resolve_asset(dir, 'db/missing.arxml#Body') == 'db/missing.arxml#Body'
	// absolute stays absolute
	abs := os.join_path(dir, 'db', 'net.arxml') + '#Body'
	assert resolve_asset('/elsewhere', abs) == abs
}
