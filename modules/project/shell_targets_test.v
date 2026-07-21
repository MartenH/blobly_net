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
		input: 0x6f0
		fc:    0x6f2
		out:   0x6f1
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
	assert shell_targets([], [], telem.SomeipIdent{}, 0, telem.ShellFrames{}).len == 0
	// a manifest-less channel derives nothing
	assert shell_targets([Channel{
		name: 'A'
	}], [true], telem.SomeipIdent{}, 0, telem.ShellFrames{}).len == 0
}

fn test_someip_only() {
	ts :=
		shell_targets([someip_chan('board', '10.0.0.5')], [true], eth_ident(), 0x800, telem.ShellFrames{})
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
	assert shell_targets([someip_chan('board', '10.0.0.5')], [true], eth_ident(), 0, telem.ShellFrames{}).len == 0
	assert shell_targets([someip_chan('board', '10.0.0.5')], [true], telem.SomeipIdent{}, 0x800, telem.ShellFrames{}).len == 0
}

fn test_someip_dup_excluded() {
	// only the FIRST someip channel carries the identity (one per project)
	ts := shell_targets([someip_chan('b1', '10.0.0.5'), someip_chan('b2', '10.0.0.6')], [
		true,
		true,
	], eth_ident(), 0x800, telem.ShellFrames{})
	assert ts.len == 1
	assert ts[0].ci == 0
}

fn test_can_only() {
	ts := shell_targets([can_chan('CAN')], [true], telem.SomeipIdent{}, 0, shell_ids())
	assert ts.len == 1
	assert !ts[0].eth
	assert ts[0].ci == 0
	assert ts[0].iface == 'vcan0'
	assert ts[0].label == 'CAN · CAN 0x6f0'
}

fn test_can_defaults_undeclared_frames() {
	// a manifest without a shell section still shells — the worker fills the
	// default ids (or_defaults), and so does the entry
	ts := shell_targets([can_chan('CAN')], [true], telem.SomeipIdent{}, 0, telem.ShellFrames{})
	assert ts.len == 1
	assert ts[0].label == 'CAN · CAN 0x7f0'
}

fn test_can_requires_usable_channel() {
	mut off := can_chan('off')
	off.enabled = false
	mut noman := can_chan('noman')
	noman.manifest = ''
	mut rep := can_chan('rep')
	rep.mode = .off
	assert shell_targets([off, noman, rep], [false, true, true], telem.SomeipIdent{}, 0,
		shell_ids()).len == 0
}

fn test_runtime_enabled_wins() {
	// the Buses panel toggles enablement WITHOUT a project rebuild — the
	// runtime flag is the truth, not the configured one
	assert shell_targets([can_chan('A')], [false], telem.SomeipIdent{}, 0, shell_ids()).len == 0
	mut cfg_off := can_chan('B')
	cfg_off.enabled = false
	assert shell_targets([cfg_off], [true], telem.SomeipIdent{}, 0, shell_ids()).len == 1
}

fn test_standalone_eth() {
	// a manifest-on-CAN eth identity with NO someip channel: the standalone-
	// socket shell is a real target (ci -1; the board ip is typed in the panel)
	ts := shell_targets([can_chan('bench')], [true], eth_ident(), 0x800, shell_ids())
	assert ts.len == 2
	assert !ts[0].eth && ts[0].ci == 0
	assert ts[1].eth && ts[1].ci == -1
	assert ts[1].label == 'manifest · eth (standalone)'
	assert ts[1].board == ''
	assert ts[1].method == 0x800
	// a someip channel claims the identity — no standalone entry then
	ts2 := shell_targets([someip_chan('board', '10.0.0.5')], [true], eth_ident(), 0x800,
		shell_ids())
	assert ts2.len == 1
	assert ts2[0].ci == 0
}

fn test_mixed_keeps_channel_order() {
	ts := shell_targets([can_chan('bench'), someip_chan('board', '10.0.0.5')], [true, true],
		eth_ident(), 0x800, shell_ids())
	assert ts.len == 2
	assert !ts[0].eth && ts[0].ci == 0
	assert ts[1].eth && ts[1].ci == 1
	assert ts[1].label == 'board · eth 10.0.0.5'
}
