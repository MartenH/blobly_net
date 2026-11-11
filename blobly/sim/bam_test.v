module sim

import blobly.candb
import blobly.j1939
import blobly.transport

const j1939_dbc = @VMODROOT + '/dbc/j1939_demo.dbc'

fn body_status() candb.Message {
	db := candb.load_dbc_file(j1939_dbc) or { panic(err) }
	m := db.message_named('BodyStatus') or { panic('no BodyStatus') }
	assert m.j1939 && m.dlc == 20
	return m
}

// steps runs `e` from 0 to `until_ms` every 5 ms and returns each frame with its time.
fn steps(mut e Engine, until_ms int) ([]transport.CanFrame, []f64) {
	mut frames := []transport.CanFrame{}
	mut at := []f64{}
	for t := 0; t <= until_ms; t += 5 {
		for f in e.due_frames(f64(t)) {
			frames << f
			at << f64(t)
		}
	}
	return frames, at
}

// A simulated node's 20-byte J1939 message goes out as a BAM a receiver rejoins: the
// announcement, then three packets 50 ms apart, from the message's source address.
fn test_a_simulated_j1939_message_past_eight_bytes_goes_out_as_a_bam() {
	msg := body_status()
	mut e := Engine{
		ecus: [
			SimEcu{
				name:     'Body'
				messages: [SimMessage{
					msg:       msg
					signals:   [SimSignal{
						name: 'Tail'
						gen:  gen_const(0xAB)
					}]
					period_ms: 1000
				}]
			},
		]
	}
	frames, at := steps(mut e, 400)
	assert frames.len == 4
	assert at == [0.0, 50, 100, 150]
	mut r := j1939.Reassembler{}
	mut done := []j1939.Assembled{}
	for k, f in frames {
		assert f.data.len == 8 && j1939.decompose(f.id).sa == 0x21
		ev := r.feed(f, at[k])
		assert ev.faults.len == 0
		done << ev.done
	}
	assert done.len == 1 && done[0].pgn == 0xFF10 && done[0].data.len == 20
	assert done[0].data[19] == 0xAB
}

// On a row that goes out CAN-FD the message is one frame, as it was.
fn test_on_an_fd_row_the_message_is_one_frame() {
	transport.replace_wire_policy_rows([], map[string]transport.Framing{}, {
		'inproc:sim_bam_fd': {
			'FD': transport.Framing{
				fd: true
			}
		}
	})
	defer {
		transport.clear_wire_framing()
	}
	mut e := Engine{
		ecus:  [SimEcu{
			name:     'Body'
			messages: [SimMessage{
				msg:       body_status()
				period_ms: 1000
			}]
		}]
		iface: 'inproc:sim_bam_fd'
		row:   'FD'
	}
	frames, _ := steps(mut e, 400)
	assert frames.len == 1 && frames[0].data.len == 20
}
