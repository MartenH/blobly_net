module project

import candb
import os

// two_clusters is dbc/example.arxml with its Body cluster copied as Chassis at 250k.
fn two_clusters() !candb.Arxml {
	src := os.read_file(os.join_path(@VMODROOT, 'dbc', 'example.arxml'))!
	a := src.index('        <CAN-CLUSTER>') or { return error('no cluster') }
	b := (src.index('</CAN-CLUSTER>') or { return error('no cluster end') }) + '</CAN-CLUSTER>'.len
	copy := src[a..b].replace_once('<SHORT-NAME>Body</SHORT-NAME>', '<SHORT-NAME>Chassis</SHORT-NAME>').replace_once('<BAUDRATE>500000</BAUDRATE>',
		'<BAUDRATE>250000</BAUDRATE>')
	path := os.join_path(os.vtmp_dir(), 'arxml_import_${os.getpid()}.arxml')
	os.write_file(path, src[..b] + '\n' + copy + src[b..])!
	defer {
		os.rm(path) or {}
	}
	return candb.load_arxml_file(path)!
}

fn test_import_maps_each_cluster_to_a_channel() {
	a := two_clusters()!
	chans, notes := import_arxml(a, ArxmlImport{
		ref:      'db/net.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'CAN1'}, ClusterPlan{'Chassis', 'vcan', 'vcan1'}]
		sut:      ['ECU_B']
		restbus:  true
	}, [])!
	assert notes == []
	assert chans.len == 2
	assert chans[0].name == 'Body'
	assert chans[0].iface == 'inproc:CAN1'
	assert chans[0].databases == ['db/net.arxml#Body']
	assert chans[0].bitrate == 500000
	// Wide is an FD frame, so the cluster runs CAN-FD at its declared data rate
	assert chans[0].fd && chans[0].typ == 'canfd' && chans[0].data_bitrate == 2000000
	assert chans[0].simulate == ['ECU_A', 'ECU_C'] // every sender but the one under test
	assert chans[1].name == 'Chassis'
	assert chans[1].iface == 'vcan1'
	assert chans[1].bitrate == 250000
	assert chans[1].databases == ['db/net.arxml#Chassis']
}

fn test_import_leaves_out_an_unmapped_cluster_and_simulates_nothing_unasked() {
	a := two_clusters()!
	chans, _ := import_arxml(a, ArxmlImport{
		ref:      'net.arxml'
		clusters: [ClusterPlan{'Body', '', ''}, ClusterPlan{'Chassis', 'virtual', 'C'}]
	}, [])!
	assert chans.map(it.name) == ['Chassis']
	assert chans[0].simulate == []
}

fn test_import_names_clear_of_existing_rows_and_says_a_shared_wire() {
	a := two_clusters()!
	existing := [
		Channel{
			name:    'Body'
			adapter: 'virtual'
			address: 'CAN1'
			iface:   'inproc:CAN1'
		},
	]
	chans, notes := import_arxml(a, ArxmlImport{
		ref:      'net.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'CAN1'}]
	}, existing)!
	assert chans[0].name == 'Body_2'
	assert notes == ['Body_2 is on inproc:CAN1, which Body already uses']
}

fn test_import_refuses_what_cannot_be_one_bus_per_wire() {
	a := two_clusters()!
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'X'}, ClusterPlan{'Chassis', 'virtual', 'X'}]
	}, []) {
		assert false, 'two clusters on one wire'
	} else {
		assert err.msg().contains('both on inproc:X')
	}
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'X'}, ClusterPlan{'Body', 'virtual', 'Y'}]
	}, []) {
		assert false, 'one cluster twice'
	} else {
		assert err.msg().contains('mapped twice')
	}
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Nope', 'virtual', 'X'}]
	}, []) {
		assert false, 'unknown cluster'
	} else {
		assert err.msg().contains('Nope')
	}
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'X'}]
		sut:      ['ECU_Z']
	}, []) {
		assert false, 'unknown ECU'
	} else {
		assert err.msg().contains('ECU_Z')
	}
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Body', 'pcan', ''}]
	}, []) {
		assert false, 'no address'
	} else {
		assert err.msg().contains('needs an address')
	}
	for adapter in ['doip', 'someip', 'bogus'] {
		if _, _ := import_arxml(a, ArxmlImport{
			ref:      'n.arxml'
			clusters: [ClusterPlan{'Body', adapter, 'x'}]
		}, []) {
			assert false, '${adapter} is not CAN'
		} else {
			assert err.msg().contains('not a CAN adapter')
		}
	}
	if _, _ := import_arxml(a, ArxmlImport{ ref: 'n.arxml' }, []) {
		assert false, 'nothing mapped'
	} else {
		assert err.msg().contains('no cluster')
	}
}

// An imported row survives a Save: the fragment, the rate and the simulated senders.
fn test_imported_rows_round_trip() {
	a := two_clusters()!
	chans, _ := import_arxml(a, ArxmlImport{
		ref:      'db/net.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'CAN1'}]
		sut:      ['ECU_B']
		restbus:  true
	}, [])!
	back := parse(Project{
		name:     'imp'
		channels: chans
	}.to_yaml())!
	assert back.channels[0].databases == ['db/net.arxml#Body']
	assert back.channels[0].fd && back.channels[0].data_bitrate == 2000000
	assert back.channels[0].simulate == ['ECU_A', 'ECU_C']
	assert back.channels[0].iface == 'inproc:CAN1'
}

// The rates, as the dialog shows them and the import writes them: FD decided by the frames, the
// data rate where stated, and what the file left out said rather than guessed.
fn test_cluster_rates() {
	a := two_clusters()!
	body := a.cluster('Body')!
	r := arxml_cluster_rates(body)
	assert r.bitrate == 500000 && r.fd && r.data_bitrate == 2000000
	assert !r.no_baudrate && !r.no_fd_rate
	assert arxml_ecus(body) == ['ECU_A', 'ECU_B', 'ECU_C']
	// an FD frame with no CAN-FD baudrate: FD, at the arbitration rate, and said
	src := os.read_file(os.join_path(@VMODROOT, 'dbc', 'example.arxml'))!
	at := src.index('<CAN-FD-BAUDRATE>') or { panic('fixture has no CAN-FD-BAUDRATE') }
	end := (src.index('</CAN-FD-BAUDRATE>') or { panic('unclosed') }) + '</CAN-FD-BAUDRATE>'.len
	path := os.join_path(os.vtmp_dir(), 'arxml_nofd_${os.getpid()}.arxml')
	os.write_file(path, src[..at] + src[end..])!
	defer {
		os.rm(path) or {}
	}
	nofd := candb.load_arxml_file(path)!
	r2 := arxml_cluster_rates(nofd.cluster('Body')!)
	assert r2.fd && r2.data_bitrate == 0 && r2.no_fd_rate
	chans, notes := import_arxml(nofd, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'B'}]
	}, [])!
	assert chans[0].fd && chans[0].data_rate() == 500000
	assert notes == ['Body: Body carries CAN-FD frames and states no CAN-FD baudrate; the data phase runs at the arbitration rate']
}

// What an address may say: `@` is literal in a software bus's name, a rate in a hardware address
// is refused (the rate is the cluster's), Vector's mode suffix becomes listen_only, and a
// combination the backend cannot open is refused before it is written.
fn test_import_address_rules() {
	a := two_clusters()!
	chans, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Body', 'virtual', 'bench@A'}, ClusterPlan{'Chassis', 'virtual', 'bench@B'}]
	}, [])!
	assert chans.map(it.iface) == ['inproc:bench@A', 'inproc:bench@B']
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Body', 'pcan', 'PCAN_USBBUS1@250000'}]
	}, []) {
		assert false, 'a rate in a hardware address'
	} else {
		assert err.msg().contains('holds a rate')
	}
	v, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Chassis', 'vector', '1,silent'}]
	}, [])!
	assert v[0].address == '1' && v[0].listen_only
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Chassis', 'vector', '1,silnt'}]
	}, []) {
		assert false, 'an unrecognised mode'
	} else {
		assert err.msg().contains('unrecognised mode')
	}
	// Body is FD at 500k: Kvaser takes it. Chassis is FD at 250k: Kvaser's FD arbitration does not
	if _, _ := import_arxml(a, ArxmlImport{
		ref:      'n.arxml'
		clusters: [ClusterPlan{'Chassis', 'kvaser', '0'}]
	}, []) {
		assert false, 'Kvaser FD at 250k'
	} else {
		assert err.msg().starts_with('Chassis on kvaser 0: unsupported Kvaser CAN-FD arbitration bitrate 250000')
	}
}

struct LookupCount {
mut:
	n int
}

fn load_for_test(ref string) ?candb.Database {
	loaded := candb.open_database(ref) or { return none }
	return loaded.db
}

// At Start, a row whose rate or format no longer matches its cluster is said — the reissued
// extract that changed a bus — and a row that matches, a disabled row, an Ethernet row, or a
// reference that does not load is not. A rate is compared only where this app sets it.
fn test_arxml_rate_warnings() {
	dir := os.join_path(os.vtmp_dir(), 'arxml_rates_${os.getpid()}')
	os.mkdir_all(dir)!
	defer {
		os.rmdir_all(dir) or {}
	}
	src := os.read_file(os.join_path(@VMODROOT, 'dbc', 'example.arxml'))!
	os.write_file(os.join_path(dir, 'net.arxml'), src)!
	// the same file with its one FD frame made classic: a cluster that carries no FD frame
	os.write_file(os.join_path(dir, 'classic.arxml'), src.replace('>CAN-FD</', '>CAN-20</'))!
	// and with no BAUDRATE: nothing stated to compare the nominal rate with
	b0 := src.index('<BAUDRATE>') or { panic('no BAUDRATE') }
	b1 := (src.index('</BAUDRATE>') or { panic('unclosed') }) + '</BAUDRATE>'.len
	os.write_file(os.join_path(dir, 'norate.arxml'), src[..b0] + src[b1..])!
	w := fn [dir] (rows []Channel) []string {
		return arxml_rate_warnings(rows, dir, load_for_test)
	}
	body := Channel{
		name:         'Body'
		adapter:      'vector'
		address:      '1'
		iface:        'vector:1'
		typ:          'canfd'
		fd:           true
		bitrate:      500000
		data_bitrate: 2000000
		databases:    ['net.arxml#Body']
	}
	assert w([body]) == []
	assert w([Channel{
		...body
		bitrate: 250000
	}]) == ['Body runs at 250000 bit/s but Body (net.arxml) is 500000 bit/s']
	assert w([Channel{
		...body
		typ:          'can'
		fd:           false
		data_bitrate: 0
	}]) == ['Body is configured classic but Body (net.arxml) carries CAN-FD frames']
	assert w([Channel{
		...body
		data_bitrate: 4000000
	}]) == ['Body runs its data phase at 4000000 bit/s but Body (net.arxml) states 2000000 bit/s']
	assert w([Channel{
		...body
		databases: ['classic.arxml#Body']
	}]) == ['Body is configured CAN-FD but Body (classic.arxml) carries no CAN-FD frame']
	// the bare file reads its only cluster, as the loader does
	assert w([Channel{
		...body
		bitrate:   1000000
		databases: ['net.arxml']
	}]).len == 1
	// where the rate is not this app's to set (`ip link`'s, or a software bus's), only the format
	vcan := Channel{
		...body
		adapter: 'vcan'
		address: 'vcan0'
		iface:   'vcan0'
		bitrate: 250000
	}
	assert w([vcan]) == []
	assert w([Channel{
		...vcan
		typ: 'can'
		fd:  false
	}]).len == 1
	// …and whether the data phase switches rate, which the row's rates decide even there
	assert w([Channel{
		...vcan
		bitrate:      500000
		data_bitrate: 500000
	}]) == ["Body's data phase does not switch rate but Body (net.arxml)'s does"]
	// no nominal rate stated: nothing to say whether its phases differ, so no BRS claim either
	assert w([Channel{
		...vcan
		bitrate:      2000000
		data_bitrate: 2000000
		databases:    ['norate.arxml#Body']
	}]) == []
	// one file under two spellings is looked up once
	mut asked := &LookupCount{} // through a pointer: a closure captures a copy of anything else
	_ = arxml_rate_warnings([Channel{
		...body
		databases: ['net.arxml#Body', '../${os.file_name(dir)}/net.arxml#Body']
	}], dir, fn [mut asked] (ref string) ?candb.Database {
		asked.n++
		return load_for_test(ref)
	})
	assert asked.n == 1
	// and a row naming one cluster twice is warned about once
	assert w([Channel{
		...body
		bitrate:   250000
		databases: ['net.arxml#Body', '../${os.file_name(dir)}/net.arxml#Body']
	}]).len == 1
	// silent: a cluster stating no baudrate, a disabled row, an Ethernet row, and what does not load
	assert w([Channel{
		...body
		bitrate:   250000
		databases: ['norate.arxml#Body']
	}]) == []
	assert w([Channel{
		...body
		bitrate: 250000
		enabled: false
	}]) == []
	// …but its finding is kept, for a front end that learns the enabled state later
	f := arxml_rate_findings([body, Channel{
		...body
		name:    'Off'
		bitrate: 250000
		enabled: false
	}], dir, load_for_test)
	assert f == [RowWarning{1, 'Off runs at 250000 bit/s but Body (net.arxml) is 500000 bit/s'}]
	assert w([Channel{
		...body
		adapter: 'doip'
		iface:   'doip:127.0.0.1'
		typ:     'doip'
		bitrate: 250000
	}]) == []
	assert w([Channel{
		...body
		bitrate:   250000
		databases: ['missing.arxml#Body', 'net.arxml#Nope', 'x.dbc']
	}]) == []
}
