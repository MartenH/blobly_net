// Tests for the decision both the GUI and the headless runner make about a DoIP channel.
// Shared on purpose: an entity that came up differently depending on which side started it
// would make a bench result depend on how the tool was launched, so the rules are pinned here
// rather than in either caller.
module sim

import project
import doip

fn ch_with(vin string) project.Channel {
	return project.Channel{
		name:     'DoIP1'
		typ:      'doip'
		iface:    'doip:127.0.0.1:13400'
		ecu_addr: 0x1000
		vin:      vin
	}
}

fn node_with(name string, vin string) project.NodeCfg {
	mut dids := []project.DidCfg{}
	if vin != '' {
		dids << project.DidCfg{
			id:   0xF190
			text: vin
		}
	}
	return project.NodeCfg{
		name: name
		uds:  project.UdsCfg{
			dids: dids
		}
	}
}

fn test_nothing_configured_serves_and_announces_the_default() {
	// The fallback server must not announce a VIN it answers NRC for.
	e := doip_entity(ch_with(''), []) or {
		assert false, '${err}'
		return
	}
	assert e.announce == doip.default_vin
	assert e.server.dids[u16(0xF190)].bytestr() == doip.default_vin
	assert e.node == ''
}

fn test_a_channel_vin_is_served_as_well_as_announced() {
	e := doip_entity(ch_with('CHANNELVIN0000001'), []) or {
		assert false, '${err}'
		return
	}
	assert e.announce == 'CHANNELVIN0000001'
	assert e.server.dids[u16(0xF190)].bytestr() == 'CHANNELVIN0000001'
}

fn test_a_configured_node_supplies_the_identity() {
	// No `vin:` on the channel: the node's DID is what discovery must advertise, not the
	// module default — that mismatch is invisible when they happen to be equal.
	e := doip_entity(ch_with(''), [node_with('SUT', 'NODEVIN0000000001')]) or {
		assert false, '${err}'
		return
	}
	assert e.announce == 'NODEVIN0000000001'
	assert e.node == 'SUT'
}

fn test_a_disagreement_between_the_two_is_refused() {
	doip_entity(ch_with('CHANNELVIN0000001'), [node_with('SUT', 'NODEVIN0000000001')]) or {
		assert err.msg().contains('two identities')
		return
	}
	assert false, 'expected a refusal, not a silently chosen winner'
}

fn test_agreement_between_the_two_is_fine() {
	e := doip_entity(ch_with('SAMEVIN0000000001'), [node_with('SUT', 'SAMEVIN0000000001')]) or {
		assert false, '${err}'
		return
	}
	assert e.announce == 'SAMEVIN0000000001'
}

fn test_a_node_without_a_vin_is_served_the_channels() {
	// Announced but not served would answer NRC 0x31 for the DID discovery just advertised.
	e := doip_entity(ch_with('CHANNELVIN0000001'), [node_with('SUT', '')]) or {
		assert false, '${err}'
		return
	}
	assert e.announce == 'CHANNELVIN0000001'
	assert e.server.dids[u16(0xF190)].bytestr() == 'CHANNELVIN0000001'
}

fn test_a_vin_the_announcement_cannot_carry_is_refused() {
	// vehicle_announcement zero-pads or truncates to 17 while the server returns it whole.
	doip_entity(ch_with(''), [node_with('SUT', 'TOOSHORT')]) or {
		assert err.msg().contains('not 17')
		return
	}
	assert false, 'expected a refusal for a VIN that cannot be announced faithfully'
}

fn test_all_nodes_rejected_is_refused_not_substituted() {
	// A broken configuration must not become a passing test against the built-in server.
	bad := project.NodeCfg{
		name: 'SUT'
		uds:  project.UdsCfg{
			malformed: ['did 0xZZ']
		}
	}
	doip_entity(ch_with(''), [bad]) or {
		assert err.msg().contains('rejected')
		return
	}
	assert false, 'expected a refusal rather than the default server in its place'
}

fn test_extra_nodes_are_counted_so_the_caller_can_say_so() {
	// One channel is one entity at one logical address; the rest have nowhere to answer.
	e := doip_entity(ch_with(''), [node_with('A', 'AAAAAAAAAAAAAAAAA'),
		node_with('B', 'BBBBBBBBBBBBBBBBB')]) or {
		assert false, '${err}'
		return
	}
	assert e.node == 'A'
	assert e.extra == 1
	assert e.announce == 'AAAAAAAAAAAAAAAAA'
}
