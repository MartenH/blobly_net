module sim

import time
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

fn j1939_node(name string, message string, period int) SimEcu {
	db := candb.load_dbc_file(j1939_dbc) or { panic(err) }
	return SimEcu{
		name:     name
		messages: [SimMessage{
			msg:       db.message_named(message) or { panic('no ${message}') }
			period_ms: period
		}]
	}
}

// between runs engines `a` and `b` on one wire every 5 ms up to `until_ms`, each frame one sends
// read by the other (its answers in turn by the first) and by a listener: what it rejoined.
fn between(mut a Engine, mut b Engine, until_ms int) []j1939.Assembled {
	mut lis := j1939.Reassembler{}
	mut done := []j1939.Assembled{}
	for t := 0; t <= until_ms; t += 5 {
		mut q := a.due_frames(f64(t)).map(Wired{it, true})
		q << b.due_frames(f64(t)).map(Wired{it, false})
		for q.len > 0 {
			w := q[0]
			q.delete(0)
			done << lis.feed(w.f, f64(t)).done
			answers := if w.from_a { b.on_frame(w.f) } else { a.on_frame(w.f) }
			q << answers.map(Wired{it, !w.from_a})
		}
	}
	return done
}

struct Wired {
	f      transport.CanFrame
	from_a bool
}

// A simulated node's long J1939 message to one node goes as an RTS/CTS connection, which a
// simulated node sending from that address answers: one message, nothing said.
fn test_a_simulated_message_to_one_node_is_a_connection_another_node_answers() {
	mut body := Engine{
		ecus: [j1939_node('Body', 'PropA_Cfg', 1000)]
	}
	// Engine sends EEC1 from 0x00 (on no cycle), so it answers for 0x00
	mut engine := Engine{
		ecus: [j1939_node('Engine', 'EEC1', 0)]
	}
	done := between(mut body, mut engine, 400)
	assert done.len == 1 && !done[0].bam && done[0].pgn == 0xEF00
	assert done[0].sa == 0x21 && done[0].da == 0x00 && done[0].data.len == 16
	assert body.conns.len == 0 && engine.answers.open() == 0
	assert body.take_notes().len == 0
}

// With nobody at the destination the connection times out, aborted, said once however often the
// message comes round.
fn test_an_unanswered_connection_is_aborted_and_said_once() {
	mut body := Engine{
		ecus: [j1939_node('Body', 'PropA_Cfg', 2000)]
	}
	mut nobody := Engine{}
	between(mut body, mut nobody, 6000)
	notes := body.take_notes()
	assert notes.len == 1 && notes[0].contains('PropA_Cfg') && notes[0].contains('no CTS'), notes.str()
	assert body.take_notes().len == 0
}

// Two of the engine's own nodes: the connection goes a hop a step, every frame on the wire in
// order — RTS, CTS, three packets, the acknowledgement.
fn test_a_connection_between_two_of_its_own_nodes() {
	mut e := Engine{
		ecus: [j1939_node('Body', 'PropA_Cfg', 1000), j1939_node('Engine', 'EEC1', 0)]
	}
	frames, at := steps(mut e, 400)
	assert frames.map(it.data[0]) == [j1939.cm_rts, j1939.cm_cts, 1, 2, 3, j1939.cm_eom_ack]
	assert at == [0.0, 5, 10, 10, 10, 15]
	mut r := j1939.Reassembler{}
	mut done := []j1939.Assembled{}
	for f in frames {
		done << r.feed(f, 0).done
	}
	assert done.len == 1 && done[0].da == 0x00 && done[0].data.len == 16
	assert e.conns.len == 0 && e.take_notes().len == 0
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

// a frame whose write took 100 ms is followed by the next a gap after the write returned
fn test_a_slow_write_moves_the_next_frame() {
	msg := body_status()
	mut e := Engine{
		ecus: [
			SimEcu{
				name:     'Body'
				messages: [SimMessage{
					msg:       msg
					period_ms: 1000
				}]
			},
		]
	}
	mut log := &SentAt{}
	for t := 0; t <= 400; t += 5 {
		e.step(f64(t), fn [mut log, t] (f transport.CanFrame) bool {
			log.at << t
			if log.at.len == 1 {
				time.sleep(100 * time.millisecond)
			}
			return true
		})
	}
	assert log.at.len == 4, '${log.at}'
	assert log.at[1] >= 150, '${log.at}'
}

struct SentAt {
mut:
	at []int
}

// Between two of its own nodes, a packet the transport refuses is not read as sent: the
// connection is not acknowledged: the responder's packets stop, it aborts, and that is said.
fn test_a_refused_packet_between_its_own_nodes_times_out() {
	mut e := Engine{
		ecus: [j1939_node('Body', 'PropA_Cfg', 2000), j1939_node('Engine', 'EEC1', 0)]
	}
	mut out := &FrameBox{}
	for t := 0; t <= 2000; t += 5 {
		e.step(f64(t), fn [mut out] (f transport.CanFrame) bool {
			if j1939.pgn(f.id) == j1939.pgn_tp_dt && f.data[0] == 2 {
				return false
			}
			out.frames << f
			return true
		})
	}
	assert !out.frames.any(it.data[0] == j1939.cm_eom_ack)
	notes := e.take_notes()
	assert notes.len == 1 && notes[0].contains('timeout'), notes.str()
}

// A simulation rebuilt mid-connection carries it on, the frames its own nodes have yet to read
// included.
fn test_a_rebuild_carries_a_connection_between_its_own_nodes_on() {
	mut e := Engine{
		ecus: [j1939_node('Body', 'PropA_Cfg', 1000), j1939_node('Engine', 'EEC1', 0)]
	}
	mut frames := e.due_frames(0)
	assert frames.len == 1 && frames[0].data[0] == j1939.cm_rts
	ecus := e.ecus
	e = e.carried()
	e.ecus = ecus
	for t := 5; t <= 100; t += 5 {
		frames << e.due_frames(f64(t))
	}
	assert frames.map(it.data[0]) == [j1939.cm_rts, j1939.cm_cts, 1, 2, 3, j1939.cm_eom_ack]
	assert e.take_notes().len == 0
}

// An abort declaring no role, from a node with a connection open each way with the engine on one
// group, ends the one that node originates: the engine's own goes on.
fn test_an_abort_with_no_role_ends_one_connection() {
	mut e := Engine{
		ecus: [j1939_node('Body', 'PropA_Cfg', 1000)]
	}
	rts := e.due_frames(0)
	assert rts.len == 1 && e.conns.len == 1
	cm := fn (data []u8) transport.CanFrame {
		return transport.CanFrame{
			id:       j1939.compose(7, j1939.pgn_tp_cm, 0x21, 0x00)
			extended: true
			data:     data
		}
	}
	assert e.on_frame(cm([j1939.cm_rts, 16, 0, 3, 0xFF, 0x00, 0xEF, 0x00])).len == 1
	assert e.answers.open() == 1
	e.on_frame(cm([j1939.cm_abort, 250, 0xFF, 0xFF, 0xFF, 0x00, 0xEF, 0x00]))
	assert e.answers.open() == 0 && e.conns.len == 1
}

// A loop ending with connections open aborts what the engine sends and answers, and lets the
// lane go for the next sender.
fn test_ending_the_connections_aborts_them_and_frees_the_lane() {
	wire := 'inproc:sim_conn_end'
	mut body := Engine{
		iface: wire
		ecus:  [j1939_node('Body', 'PropA_Cfg', 1000)]
	}
	mut engine := Engine{
		ecus: [j1939_node('Engine', 'EEC1', 0)]
	}
	rts := body.due_frames(0)
	assert rts.len == 1 && rts[0].data[0] == j1939.cm_rts
	assert engine.on_frame(rts[0]).len == 1 && engine.answers.open() == 1
	mut out := &FrameBox{}
	collect := fn [mut out] (f transport.CanFrame) bool {
		out.frames << f
		return true
	}
	body.end_connections(collect)
	engine.end_connections(collect)
	assert out.frames.map(it.data[..3]) == [[j1939.cm_abort, u8(250), 0xFC], [j1939.cm_abort, u8(250), 0xFD]]
	assert body.conns.len == 0 && engine.answers.open() == 0
	next := j1939.connection_for(transport.CanFrame{ ...rts[0], id: j1939.compose(6, 0xEF00, 0x00,
		0x21), data: []u8{len: 16} }, wire, 0)!
	assert next.take_lane(time.sys_mono_now())
}
