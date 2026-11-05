module project

import os

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

fn test_lin_section_parses() {
	p := parse(sim_demo_text() + lin_section)!
	assert p.lin.len == 2
	b := p.lin[0]
	assert b.name == 'BODY' && b.address == 'inproc:body' && b.bitrate == 19200
	assert b.ldf == 'dbc/lin_demo.ldf' && b.role == 'master' && b.schedule == 'NormalTable'
	assert b.simulate == ['CEM', 'LSM'] && b.enabled
	d := p.lin[1]
	assert d.role == 'monitor' && !d.enabled && d.bitrate == 0 && d.ldf == ''
}

// The rows of buses: are the same with or without a lin: section.
fn test_lin_does_not_touch_the_channels() {
	without := parse(sim_demo_text())!
	with := parse(sim_demo_text() + lin_section)!
	assert with.channels.len == without.channels.len
	assert Project{
		...with
		lin: []
	}.to_yaml() == without.to_yaml()
}

// A project without LIN saves exactly as before; adding LIN only raises the version and
// appends the section, and it round-trips.
fn test_lin_save_is_additive_and_round_trips() {
	without := parse(sim_demo_text())!
	before := without.to_yaml()
	assert !before.contains('\nlin:')
	assert version_for(without) < 11
	with := parse(sim_demo_text() + lin_section)!
	after := with.to_yaml()
	assert version_for(with) == 11
	assert after.starts_with(before.replace('version: ${version_for(without)}\n', 'version: 11\n'))
	back := parse(after)!
	assert back.lin == with.lin
	assert back.to_yaml() == after
}

fn test_lin_refusals_name_the_problem() {
	cases := {
		'  - name: B\n    address: inproc:b\n    speed: 1\n':                       'unknown key `speed`'
		'  - name: B\n    address: inproc:b\n    role: boss\n':                     'role `boss`'
		'  - address: inproc:b\n':                                                  'needs a name'
		'  - name: B\n':                                                            'needs an address'
		'  - name: B\n    address: inproc:b\n    bitrate: 50000\n':                 'bitrate must be 1000..20000'
		'  - name: B\n    address: inproc:b\n  - name: B\n    address: inproc:c\n': 'two LIN buses are named `B`'
		'  - name: CAN1\n    address: inproc:b\n':                                  'is both a channel of buses: and a LIN bus'
	}
	for body, want in cases {
		parse(sim_demo_text() + '\nlin:\n' + body) or {
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
	assert q.lin[0].ldf == '../proj/dbc/lin_demo.ldf'
	q.restore_assets(was)
	assert q.lin[0].ldf == 'dbc/lin_demo.ldf'
}

// The clash is one predicate a front end can ask before it saves: a channel renamed like a LIN bus.
fn test_lin_name_clash_is_asked_of_the_model() {
	mut p := load(os.join_path(@VMODROOT, 'projects', 'lin-demo.blobnet'))!
	assert p.name_clash('CAN1') == none && p.name_clash('BODY') == none
	assert p.name_taken('BODY') && p.name_taken('CAN1') && !p.name_taken('CAN2')
	p.channels[0].name = 'BODY'
	why := p.name_clash('BODY') or { '' }
	assert why.contains('both a channel of buses: and a LIN bus'), why
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
	assert p.lin[0].simulate == []
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
	assert newer.lin.len == 1 && newer.version_note() != ''
	if _ := parse('project:\n  name: t\n  version: ${schema_version}\n' + body) {
		assert false, 'a typo at the current schema read'
	} else {
		assert err.msg().contains('unknown key `break_len`'), err.msg()
	}
}
