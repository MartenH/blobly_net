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

// A long J1939 message to one node, which only RTS/CTS carries, is not sent, and is said once.
fn test_a_message_to_one_node_is_said_once_and_not_sent() {
	db := candb.load_dbc_file(j1939_dbc) or { panic(err) }
	msg := db.message_named('PropA_Cfg') or { panic('no PropA_Cfg') }
	assert msg.j1939 && msg.dlc > 8
	mut e := Engine{
		ecus: [SimEcu{
			name:     'Body'
			messages: [SimMessage{
				msg:       msg
				period_ms: 100
			}]
		}]
	}
	frames, _ := steps(mut e, 400)
	assert frames.len == 0
	notes := e.take_notes()
	assert notes.len == 1 && notes[0].contains('PropA_Cfg') && notes[0].contains('RTS/CTS')
	assert e.take_notes().len == 0
}

fn body_engine() Engine {
	return Engine{
		ecus: [SimEcu{
			name:     'Body'
			messages: [SimMessage{
				msg:       body_status()
				period_ms: 1000
			}]
		}]
	}
}

@[heap]
struct Refuse {
mut:
	after int // frames taken before every next one is refused
	seen  int
}

// A BAM's message is last sent once every frame of it is on the wire, not when it is queued; one
// that a frame of is refused is not sent at all.
fn test_a_bam_is_the_last_sent_only_once_it_is_whole() {
	mut e := body_engine()
	e.step(0, fn (f transport.CanFrame) bool {
		return true
	})
	assert e.ecus[0].messages[0].last_n == -1, 'only the announcement is out'
	for t := 5; t <= 150; t += 5 {
		e.step(f64(t), fn (f transport.CanFrame) bool {
			return true
		})
	}
	assert e.ecus[0].messages[0].last_n == 0 && e.ecus[0].messages[0].last_t == 0
	assert e.tp_sent.len == 0
	mut r := &Refuse{
		after: 2
	}
	mut refused := body_engine()
	for t := 0; t <= 400; t += 5 {
		refused.step(f64(t), fn [mut r] (f transport.CanFrame) bool {
			r.seen++
			return r.seen <= r.after
		})
	}
	assert r.seen == 3, 'the refused frame ends the transfer'
	assert refused.ecus[0].messages[0].last_n == -1
	assert refused.tp_sent.len == 0
}
