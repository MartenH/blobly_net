module sim

import candb

fn faulted_msg() candb.Message {
	return candb.Message{
		name: 'Protected'
		id:   0x123
		dlc:  8
		signals: [
			candb.Signal{
				name:       'AliveCounter'
				start_bit:  0
				length:     4
				byte_order: .little_endian
				factor:     1
			},
			candb.Signal{
				name:       'Speed'
				start_bit:  8
				length:     16
				byte_order: .little_endian
				factor:     1
				minimum:    0
				maximum:    250
			},
			candb.Signal{
				name:       'CRC'
				start_bit:  56
				length:     8
				byte_order: .little_endian
				factor:     1
			},
		]
	}
}

fn protected_engine(f Fault) Engine {
	return Engine{
		ecus: [SimEcu{
			name:     'ECU'
			messages: [SimMessage{
				msg:       faulted_msg()
				period_ms: 10
				e2e:       E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
				fault:     f
			}]
		}]
	}
}

// A dropped message must not appear on the bus at all — that is what provokes the receiver's
// timeout handling and its DTC.
fn test_drop_removes_the_frame_but_keeps_the_cycle() {
	mut e := protected_engine(Fault{ kind: .drop })
	mut sent := 0
	for t in [f64(0), 10, 20, 30] {
		sent += e.due_frames(t).len
	}
	assert sent == 0, 'a dropped message must not be transmitted'
	// the ECU is still running: its counter has moved on, so recovery shows a GAP, not a stall
	assert e.ecus[0].messages[0].send_n == 4
}

// The checksum must be WRONG, and wrong in a way a receiver cannot accept by coincidence.
fn test_bad_crc_differs_from_the_correct_one() {
	mut good := protected_engine(Fault{})
	mut bad := protected_engine(Fault{ kind: .bad_crc })
	g := good.due_frames(0)[0]
	b := bad.due_frames(0)[0]
	assert g.data[..7] == b.data[..7], 'only the checksum may differ'
	assert g.data[7] != b.data[7], 'the checksum must not survive corruption'
	assert b.data[7] == u8(255) - g.data[7], 'every bit inverted, so it cannot coincide with a valid value'
}

// A frozen counter is a sender that stopped advancing — the receiver sees the same value
// cycle after cycle, which is exactly what an alive counter exists to catch.
fn test_freeze_counter_stops_the_sequence_without_stopping_traffic() {
	mut e := protected_engine(Fault{ kind: .freeze_ctr })
	mut seen := []u8{}
	for t in [f64(0), 10, 20, 30] {
		seen << e.due_frames(t)[0].data[0] & 0x0F
	}
	assert seen == [u8(0), 0, 0, 0], 'the counter must not advance, got ${seen}'
	assert e.ecus[0].messages[0].send_n == 0, 'the send count is what is held back'
}

// Out of range means outside the DBC's declared maximum, not merely a large number.
fn test_out_of_range_exceeds_the_declared_maximum() {
	mut e := protected_engine(Fault{ kind: .out_of_range, signal: 'Speed' })
	f := e.due_frames(0)[0]
	raw := u64(f.data[1]) | (u64(f.data[2]) << 8)
	assert raw == 0xFFFF, 'the signal must carry its maximum encodable value'
	assert f64(raw) > 250, 'and that must exceed the declared maximum'
	assert can_force_out_of_range(faulted_msg(), 'Speed')
	// a signal with no declared range has no out-of-range value to send
	assert !can_force_out_of_range(faulted_msg(), 'AliveCounter')
}

// A timed fault expires by itself: "drop for three seconds and watch the DTC" is the gesture,
// and a fault that must be switched off by hand gets left on.
fn test_timed_fault_expires() {
	mut f := Fault{ kind: .drop, remaining_ms: 100 }
	assert f.tick(40)
	assert f.tick(40)
	assert !f.tick(40), 'it must expire once its time is spent'
	assert f.kind == .none_
	assert !f.active()

	mut forever := Fault{ kind: .drop }
	assert forever.tick(100_000), 'an untimed fault stays until switched off'
}

// The checksum is corrupted AFTER protection has stamped it. The other order produces a valid
// checksum for corrupted data, which a receiver accepts and no test notices.
fn test_corruption_happens_after_protection() {
	mut e := protected_engine(Fault{ kind: .bad_crc })
	f := e.due_frames(0)[0]
	mut recomputed := f.data.clone()
	m := faulted_msg()
	for sig in m.signals {
		if sig.name == 'CRC' {
			sig.set_raw(mut recomputed, 0)
			break
		}
	}
	want := crc8_j1850(recomputed)
	assert f.data[7] != want, 'the frame must NOT validate against its own contents'
}

// Ageing is driven by a wall-clock instant and is idempotent across callers — one simulation
// loop per bus calls it, and an elapsed-time argument made each subtract the same interval
// again, so a two-bus project expired every timed fault twice as fast.
//
// A timed fault must expire even though the engine is re-stamped from the shared table every
// pass: a countdown kept on the engine's copy is overwritten with its original value each time,
// so "drop for 500 ms" dropped forever. The ageing belongs on the table.
fn test_timed_fault_ages_on_the_shared_table() {
	mut t := FaultTable{}
	t.set(fault_key('ECU', 'Msg'), Fault{ kind: .drop, remaining_ms: 100 })
	mut e := Engine{
		ecus: [SimEcu{
			name:     'ECU'
			messages: [SimMessage{ msg: faulted_msg(), period_ms: 10 }]
		}]
	}
	e.ecus[0].messages[0].msg.name = 'Msg'

	t.age_to(1000) // establishes the clock
	t.age_to(1040)
	t.apply_to(mut e)
	assert e.ecus[0].messages[0].fault.kind == .drop, 'still in force after 40ms'

	t.age_to(1120) // past its 100ms lifetime
	t.apply_to(mut e)
	assert e.ecus[0].messages[0].fault.kind == .none_, 'must have expired'
	assert t.get(fault_key('ECU', 'Msg')).kind == .none_, 'and be gone from the table'

	// an untimed fault is untouched by ageing
	t.set(fault_key('ECU', 'Msg'), Fault{ kind: .bad_crc })
	t.age_to(20_000)
	assert t.get(fault_key('ECU', 'Msg')).kind == .bad_crc
}
