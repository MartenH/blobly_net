module project

import telem

fn eth_ident() telem.SomeipIdent {
	return telem.SomeipIdent{
		service: 0x1234
		version: 1
		port:    40509
		peer:    '127.0.0.1:40999'
	}
}

fn shell_ids() telem.ShellFrames {
	return telem.ShellFrames{
		input: 0x7f0
		fc:    0x7f2
		out:   0x7f1
	}
}

fn can_chan(name string) Channel {
	return Channel{
		name:     name
		manifest: 'target.csv'
	}
}

fn someip_chan(name string, ip string) Channel {
	return Channel{
		name:    name
		adapter: 'someip'
		typ:     'someip'
		address: ip
		iface:   'someip:${ip}'
	}
}

fn test_none() {
	assert shell_targets([], eth_ident(), 0x800, shell_ids()).len == 0
	// channels without manifests/identity derive nothing
	assert shell_targets([Channel{
		name: 'A'
	}], telem.SomeipIdent{}, 0, telem.ShellFrames{}).len == 0
}

fn test_someip_only() {
	ts := shell_targets([someip_chan('board', '10.0.0.5')], eth_ident(), 0x800, telem.ShellFrames{})
	assert ts.len == 1
	assert ts[0].eth
	assert ts[0].ci == 0
	assert ts[0].label == 'board · eth 10.0.0.5'
	assert ts[0].board == '10.0.0.5'
	assert ts[0].sip.service == 0x1234
	assert ts[0].method == 0x800
}

fn test_someip_needs_identity() {
	// an eth image without a shell endpoint (method 0) is no target
	assert shell_targets([someip_chan('board', '10.0.0.5')], eth_ident(), 0, shell_ids()).len == 0
	assert shell_targets([someip_chan('board', '10.0.0.5')], telem.SomeipIdent{}, 0x800,
		shell_ids()).len == 0
}

fn test_someip_dup_excluded() {
	// only the FIRST someip channel carries the identity (one per project)
	ts := shell_targets([someip_chan('b1', '10.0.0.5'), someip_chan('b2', '10.0.0.6')],
		eth_ident(), 0x800, telem.ShellFrames{})
	assert ts.len == 1
	assert ts[0].ci == 0
}

fn test_can_only() {
	ts := shell_targets([can_chan('CAN')], telem.SomeipIdent{}, 0, shell_ids())
	assert ts.len == 1
	assert !ts[0].eth
	assert ts[0].ci == 0
	assert ts[0].label == 'CAN · CAN 0x7f0'
}

fn test_can_requires_shell_frames() {
	// no declared cmd/rsp ids -> no CAN entry (or_defaults stays legacy-only)
	assert shell_targets([can_chan('CAN')], telem.SomeipIdent{}, 0, telem.ShellFrames{}).len == 0
	assert shell_targets([can_chan('CAN')], telem.SomeipIdent{}, 0, telem.ShellFrames{
		input: 0x7f0
	}).len == 0
}

fn test_can_requires_usable_channel() {
	mut off := can_chan('off')
	off.enabled = false
	mut noman := can_chan('noman')
	noman.manifest = ''
	mut rep := can_chan('rep')
	rep.mode = .off
	assert shell_targets([off, noman, rep], telem.SomeipIdent{}, 0, shell_ids()).len == 0
}

fn test_mixed_keeps_channel_order() {
	ts := shell_targets([can_chan('bench'), someip_chan('board', '10.0.0.5')], eth_ident(), 0x800,
		shell_ids())
	assert ts.len == 2
	assert !ts[0].eth && ts[0].ci == 0
	assert ts[1].eth && ts[1].ci == 1
	assert ts[1].label == 'board · eth 10.0.0.5'
}
