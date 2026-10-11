module candb

// Transmitter-node + node-list parsing (used to map messages to simulated ECUs)
// and the GenMsgCycleTime attribute.

const sender_dbc = 'VERSION ""

BU_: EngineECU BodyECU Tester

BO_ 256 Powertrain: 8 EngineECU
 SG_ EngineSpeed : 0|16@1+ (0.25,0) [0|16383.75] "rpm" Tester

BO_ 2566848512 ExtFrame: 8 BodyECU
 SG_ Foo : 0|8@1+ (1,0) [0|255] "" Tester

BO_ 257 Request: 8 Tester
 SG_ Cmd : 0|8@1+ (1,0) [0|255] "" EngineECU

BA_ "GenMsgCycleTime" BO_ 256 100;
'

fn test_nodes_parsed() {
	db := parse_dbc(sender_dbc) or { panic(err) }
	assert db.nodes == ['EngineECU', 'BodyECU', 'Tester']
}

fn test_sender_and_ext() {
	db := parse_dbc(sender_dbc) or { panic(err) }
	pt := db.lookup(256) or {
		assert false, 'no Powertrain'
		return
	}
	assert pt.sender == 'EngineECU'
	assert !pt.ext
	assert pt.cycle_ms == 100
	// 2566848512 = 0x98FF0000 -> EFF flag set, real id 0x18FF0000
	ext := db.lookup(0x18FF0000) or {
		assert false, 'no ext frame'
		return
	}
	assert ext.ext
	assert ext.sender == 'BodyECU'
}

fn test_messages_from() {
	db := parse_dbc(sender_dbc) or { panic(err) }
	engine_msgs := db.messages_from('EngineECU')
	assert engine_msgs.len == 1
	assert engine_msgs[0].name == 'Powertrain'
	tester_msgs := db.messages_from('Tester')
	assert tester_msgs.len == 1
	assert tester_msgs[0].name == 'Request'
	assert db.messages_from('Nobody').len == 0
}
