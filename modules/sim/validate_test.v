module sim

import candb

const validate_dbc = 'VERSION "t"

BU_: SUT Other

BO_ 256 Powertrain: 8 SUT
 SG_ EngineSpeed : 0|16@1+ (1,0) [0|0] "rpm" Vector__XXX
 SG_ VehicleSpeed : 16|8@1+ (1,0) [0|0] "km/h" Vector__XXX
'

fn test_validate_node() {
	db := candb.parse_dbc(validate_dbc)!
	// valid node + valid signals -> no warnings
	assert validate_node(db, 'SUT', ['EngineSpeed', 'VehicleSpeed']).len == 0
	// unknown node -> one warning, signals not checked
	w_node := validate_node(db, 'Ghost', ['EngineSpeed'])
	assert w_node.len == 1
	assert w_node[0].contains('sends no message')
	// known node, one bad signal -> one warning naming it
	w_sig := validate_node(db, 'SUT', ['EngineSpeed', 'Bogus'])
	assert w_sig.len == 1
	assert w_sig[0].contains('Bogus')
	// a signal that belongs to another node's message isn't valid for SUT here
	// (Other transmits nothing in this DBC), and empty names are skipped
	assert validate_node(db, 'SUT', ['']).len == 0
}

// A DBC with BO_ senders but no BU_ list still builds a working ECU, so validation must not
// claim the configuration will not take effect while it is transmitting.
fn test_validate_node_accepts_a_bo_only_transmitter() {
	db := candb.Database{
		nodes:    [] // no BU_ at all
		messages: [candb.Message{
			name:   'Status'
			id:     0x300
			dlc:    8
			sender: 'BCM'
			signals: [candb.Signal{ name: 'State', start_bit: 0, length: 8, factor: 1 }]
		}]
	}
	assert validate_node(db, 'BCM', ['State']).len == 0, 'a BO_ sender is a valid node'
	w := validate_node(db, 'Ghost', [])
	assert w.len == 1 && w[0].contains('sends no message')
}
