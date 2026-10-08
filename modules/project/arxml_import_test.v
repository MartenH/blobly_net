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
