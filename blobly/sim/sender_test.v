module sim

import blobly.candb
import blobly.project

// a message generator's frame: the DBC's id and DLC, each listed signal encoded, its value
// source evaluated at the send index — the builder the GUI and the headless runner share
fn test_sender_message_frame_encodes_and_evaluates_sources() {
	db := candb.parse_dbc('BO_ 256 M: 2 T
 SG_ A : 0|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ B : 8|8@1+ (1,0) [0|255] "" Vector__XXX
') or { panic(err) }
	s := project.Sender{
		name:    'g'
		message: 'M'
		signals: [
			project.SenderSig{
				name:  'A'
				value: 7
			},
			project.SenderSig{
				name: 'B'
				wave: project.GenCfg{
					typ:    'counter'
					start:  10
					step:   1
					modulo: 256
				}
			},
		]
	}
	f := sender_message_frame(s, [db], 3, 0.0) or { panic('M not built') }
	assert f.id == 256 && !f.extended
	assert f.data == [u8(7), 13] // the counter at send 3: 10 + 3
	assert sender_message_frame(project.Sender{ message: 'Nope' }, [db], 0, 0.0) == none
}

// a multiplexed signal is encoded only where the switch selects its branch: a value kept for the
// other branch does not land on the shared bits
fn test_sender_message_frame_encodes_the_selected_branch_only() {
	db := candb.parse_dbc('BO_ 256 M: 2 T
 SG_ Mux M : 0|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ A m1 : 8|8@1+ (1,0) [0|255] "" Vector__XXX
 SG_ B m2 : 8|8@1+ (1,0) [0|255] "" Vector__XXX
') or { panic(err) }
	mut s := project.Sender{
		name:    'g'
		message: 'M'
		signals: [project.SenderSig{
			name:  'A'
			value: 10
		}, project.SenderSig{
			name:  'Mux'
			value: 1
		}, project.SenderSig{
			name:  'B'
			value: 20
		}]
	}
	assert (sender_message_frame(s, [db], 0, 0.0) or { panic('M') }).data == [u8(1), 10]
	s.signals[1].value = 2
	assert (sender_message_frame(s, [db], 0, 0.0) or { panic('M') }).data == [u8(2), 20]
}
