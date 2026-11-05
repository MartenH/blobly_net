module project

import os

const lin_rows = '
  - name: BODY
    adapter: lin
    address: inproc:body
    bitrate: 19200
    ldf: dbc/lin_demo.ldf
    role: master
    simulate: [CEM, LSM]
    schedule: NormalTable
  - name: DOOR
    interface: lin:pty:/dev/pts/4
    enabled: false
'

const lin_section = '
lin:
  - name: BODY
    address: inproc:body
    bitrate: 19200
    ldf: dbc/lin_demo.ldf
    role: master
    simulate: [CEM, LSM]
    schedule: NormalTable
  - name: DOOR
    address: pty:/dev/pts/4
    enabled: false
'

fn sim_demo_text() string {
	return os.read_file(os.join_path(@VMODROOT, 'projects', 'sim-demo.blobnet')) or { panic(err) }
}

// with_rows is sim-demo with LIN rows first in its buses: (`channels:` there).
fn with_rows(rows string) string {
	text := sim_demo_text()
	key := if text.contains('\nbuses:\n') { '\nbuses:\n' } else { '\nchannels:\n' }
	i := text.index(key) or { panic('no buses:') } + key.len
	return text[..i] + rows.trim_left('\n') + text[i..]
}

fn check_parsed(p Project) {
	bs := p.lin_rows()
	assert bs.len == 2
	b := bs[0]
	assert b.name == 'BODY' && b.address == 'inproc:body' && b.bitrate == 19200
	assert b.ldf == 'dbc/lin_demo.ldf' && b.lin_role == 'master' && b.schedule == 'NormalTable'
	assert b.simulate == ['CEM', 'LSM'] && b.enabled
	d := bs[1]
	assert d.name == 'DOOR' && d.address == 'pty:/dev/pts/4'
	assert d.lin_role == 'monitor' && !d.enabled && d.bitrate == 0 && d.ldf == ''
	row := p.channels.filter(it.name == 'BODY')[0]
	assert row.kind() == .lin && row.iface == 'lin:inproc:body' && !row.kind().has_generators()
}

// A LIN bus is a row of buses:, and a v11 file's lin: list reads as the same rows.
fn test_a_lin_bus_is_a_row_and_the_old_section_reads_as_one() {
	rows := parse(with_rows(lin_rows))!
	check_parsed(rows)
	old := parse(sim_demo_text() + lin_section)!
	check_parsed(old)
	assert old.lin_rows() == rows.lin_rows()
	assert old.channels.filter(it.kind() == .lin).map(it.iface) == ['lin:inproc:body',
		'lin:pty:/dev/pts/4']
}

// A project without LIN saves exactly as before; LIN rows are written in buses: at v12, and
// read back the same; an old lin: section is saved as rows.
fn test_lin_rows_save_and_round_trip() {
	without := parse(sim_demo_text())!
	assert version_for(without) < 12
	assert !without.to_yaml().contains('adapter: lin')
	for text in [with_rows(lin_rows), sim_demo_text() + lin_section] {
		p := parse(text)!
		after := p.to_yaml()
		assert version_for(p) == 12
		assert !after.contains('\nlin:') && after.contains('    adapter: lin\n')
		back := parse(after)!
		assert back.lin_rows() == p.lin_rows()
		assert back.to_yaml() == after
	}
}

fn test_lin_refusals_name_the_problem() {
	cases := {
		'  - name: B\n    address: inproc:b\n    speed: 1\n':                       'unknown key `speed`'
		'  - name: B\n    address: inproc:b\n    role: boss\n':                     'role `boss`'
		'  - address: inproc:b\n':                                                  'needs a name'
		'  - name: B\n':                                                            'needs an address'
		'  - name: B\n    address: inproc:b\n    bitrate: 50000\n':                 'bitrate must be 1000..20000'
		'  - name: B\n    address: inproc:b\n  - name: B\n    address: inproc:c\n': 'names a LIN bus and another row'
		'  - name: CAN1\n    address: inproc:b\n':                                  'names a LIN bus and another row'
	}
	for body, want in cases {
		parse(sim_demo_text() + '\nlin:\n' + body) or {
			assert err.msg().contains(want), '${want}: ${err.msg()}'
			continue
		}
		assert false, 'not refused: ${want}'
	}
	// and as rows: a key a LIN bus has no use for is refused, not carried
	for row, want in {
		'  - name: B\n    adapter: lin\n    address: inproc:b\n    databases: [x.dbc]\n': 'unknown key `databases` for a LIN bus'
		'  - name: B\n    adapter: lin\n':                                            'needs an address'
		'  - name: CAN1\n    adapter: lin\n    address: inproc:b\n':                  'names a LIN bus and another row'
	} {
		parse(with_rows(row)) or {
			assert err.msg().contains(want), '${want}: ${err.msg()}'
			continue
		}
		assert false, 'not refused: ${want}'
	}
}

fn test_lin_ldf_is_a_reference() {
	p := parse(sim_demo_text() + lin_section)!
	assert 'dbc/lin_demo.ldf' in p.references()
	root := os.join_path(os.vtmp_dir(), 'lin_refs_${os.getpid()}')
	os.mkdir_all(os.join_path(root, 'proj'))!
	defer {
		os.rmdir_all(root) or {}
	}
	os.chdir(@VMODROOT)!
	notes := p.reference_notes(os.join_path(root, 'proj'), [])
	assert notes.any(it.starts_with('BODY: `dbc/lin_demo.ldf` resolves only from')), notes.str()
	os.mkdir_all(os.join_path(root, 'proj', 'dbc'))!
	os.write_file(os.join_path(root, 'proj', 'dbc', 'lin_demo.ldf'), '')!
	mut q := p
	was := q.rebase_assets(os.join_path(root, 'proj'), os.join_path(root, 'other'))
	assert q.lin_rows()[0].ldf == '../proj/dbc/lin_demo.ldf'
	q.restore_assets(was)
	assert q.lin_rows()[0].ldf == 'dbc/lin_demo.ldf'
}

// The clash is one predicate a front end can ask before it saves: a channel renamed like a LIN bus.
fn test_lin_name_clash_is_asked_of_the_model() {
	mut p := load(os.join_path(@VMODROOT, 'projects', 'lin-demo.blobnet'))!
	assert p.name_clash('CAN1') == none && p.name_clash('BODY') == none
	assert p.name_taken('BODY') && p.name_taken('CAN1') && !p.name_taken('CAN2')
	p.channels[0].name = 'BODY'
	why := p.name_clash('BODY') or { '' }
	assert why.contains('names a LIN bus and another row'), why
	if _ := parse(p.to_yaml()) {
		assert false, 'the clash read back'
	} else {
		assert err.msg().contains(why), err.msg()
	}
}

// An empty simulate: is no node, in either section; an item that is not a name is refused.
fn test_simulate_null_is_empty_and_items_are_names() {
	p := parse('project:\n  name: t\nbuses:\n  - name: CAN1\n    interface: inproc:x\n    simulate:\nlin:\n  - name: B\n    address: inproc:b\n    simulate: ~\n')!
	assert p.channels[0].simulate == []
	assert p.lin_rows()[0].simulate == []
	assert !p.to_yaml().contains('null')
	if _ := parse('lin:\n  - name: B\n    address: inproc:b\n    simulate: [{ a: 1 }]\n') {
		assert false, 'a mapping read as a node'
	} else {
		assert err.msg().contains('lin B: simulate: item 1 is not a name'), err.msg()
	}
	if _ := parse('buses:\n  - name: CAN1\n    interface: inproc:x\n    simulate: [[A]]\n') {
		assert false, 'a list read as a node'
	} else {
		assert err.msg().contains('CAN1: simulate: item 1 is not a name'), err.msg()
	}
}

// An unknown lin: key is a typo at this build's schema, and a newer file's own key otherwise.
fn test_unknown_lin_key_in_a_newer_file_is_ignored() {
	body := 'lin:\n  - name: B\n    address: inproc:b\n    break_len: 13\n'
	newer := parse('project:\n  name: t\n  version: ${schema_version + 1}\n' + body)!
	assert newer.lin_rows().len == 1 && newer.version_note() != ''
	if _ := parse('project:\n  name: t\n  version: ${schema_version}\n' + body) {
		assert false, 'a typo at the current schema read'
	} else {
		assert err.msg().contains('unknown key `break_len`'), err.msg()
	}
}

// The editor's commit asks what the reader refuses; a bare lin interface names no address.
fn test_a_lin_rows_address_and_rate_are_checked_as_the_file_is() {
	assert lin_row_refusal('inproc:b', '') == none && lin_row_refusal('inproc:b', '0') == none
	assert lin_row_refusal('inproc:b', '19200') == none
	for addr, rate in {
		'':         '19200'
		'inproc:b': '500000'
		'inproc:x': 'abc'
		'inproc:y': '999'
	} {
		assert lin_row_refusal(addr, rate) != none, '${addr} ${rate}'
	}
	a, addr := decompose_iface('lin:pty:/tmp/lin_slave_0,plain')
	assert a == 'lin' && addr == 'pty:/tmp/lin_slave_0,plain'
	b, none_addr := decompose_iface('lin')
	assert b == 'lin' && none_addr == ''
	// an address typed into a CAN row does not make it a LIN row
	assert Channel{
		adapter: 'vcan'
		iface:   'lin:inproc:body'
	}.kind() == .can
	if _ := parse('buses:\n  - name: B\n    interface: lin\n') {
		assert false, 'a bare lin read'
	} else {
		assert err.msg().contains('needs an address'), err.msg()
	}
}
