module sim

import candb
import transport

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
	assert e.ecus[0].messages[0].e2e_n == 4
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
	// last_e2e is what the wire saw; e2e_n is the next value, one step past it and untouched by
	// the freeze — which is exactly why recovery needs no transition flag.
	assert e.ecus[0].messages[0].last_e2e == 0, 'the TRANSMITTED counter is what is held back'
	assert e.ecus[0].messages[0].send_n == 4, 'generators keep running — only E2E stalls'
}

// Out of range means outside the DBC's declared maximum, not merely a large number.
fn test_out_of_range_exceeds_the_declared_maximum() {
	mut e := protected_engine(Fault{ kind: .out_of_range, signal: 'Speed' })
	f := e.due_frames(0)[0]
	raw := u64(f.data[1]) | (u64(f.data[2]) << 8)
	assert raw == 0xFFFF, 'the signal must carry its maximum encodable value'
	assert f64(raw) > 250, 'and that must exceed the declared maximum'
	prot := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	assert can_force_out_of_range(faulted_msg(), 'Speed', prot)
	// a signal with no declared range has no out-of-range value to send
	assert !can_force_out_of_range(faulted_msg(), 'AliveCounter', prot)
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
	t.set(fault_key('inproc:B', 'ECU', 'Msg'), Fault{ kind: .drop, remaining_ms: 100 })
	mut e := Engine{
		ecus: [SimEcu{
			name:     'ECU'
			messages: [SimMessage{ msg: faulted_msg(), period_ms: 10 }]
		}]
	}
	e.ecus[0].messages[0].msg.name = 'Msg'

	t.age_to(1000) // establishes the clock
	t.age_to(1040)
	t.apply_to('inproc:B', mut e)
	assert e.ecus[0].messages[0].fault.kind == .drop, 'still in force after 40ms'

	t.age_to(1120) // past its 100ms lifetime
	t.apply_to('inproc:B', mut e)
	assert e.ecus[0].messages[0].fault.kind == .none_, 'must have expired'
	assert t.get(fault_key('inproc:B', 'ECU', 'Msg')).kind == .none_, 'and be gone from the table'

	// an untimed fault is untouched by ageing
	t.set(fault_key('inproc:B', 'ECU', 'Msg'), Fault{ kind: .bad_crc })
	t.age_to(20_000)
	assert t.get(fault_key('inproc:B', 'ECU', 'Msg')).kind == .bad_crc
}

// A violation written into a protection field is overwritten when the checksum is stamped, so
// the frame goes out perfectly valid and the fault tests nothing. Those fields are not offered.
fn test_protection_fields_are_not_offered_for_range_faults() {
	m := faulted_msg()
	prot := E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
	assert !can_force_out_of_range(m, 'CRC', prot), 'the checksum field cannot carry it'
	assert !can_force_out_of_range(m, 'AliveCounter', prot), 'nor the counter field'
	assert can_force_out_of_range(m, 'Speed', prot)
	// with no protection configured, the same signals are judged on their own merits
	bare := E2e{}
	assert !can_force_out_of_range(m, 'AliveCounter', bare), 'no declared range'
}

// A negative factor puts the physical maximum at raw ZERO, so testing all-ones alone reported
// "no illegal value" for a signal that plainly has one.
fn test_negative_factor_finds_its_endpoint() {
	sig := candb.Signal{
		name:       'Inverted'
		start_bit:  0
		length:     8
		byte_order: .little_endian
		factor:     -1
		offset:     255
		minimum:    0
		maximum:    200
	}
	v := illegal_raw(sig) or { panic('no illegal value found for a signal that has one') }
	assert sig.phys_from_raw(v) > 200, 'the chosen endpoint must actually violate'
}

// Leaving a freeze must not repeat the frozen value once more.
fn test_counter_resumes_cleanly_after_a_freeze() {
	mut e := protected_engine(Fault{ kind: .freeze_ctr })
	for t in [f64(0), 10, 20] {
		e.due_frames(t)
	}
	frozen := e.ecus[0].messages[0].last_e2e
	// clear the fault, as expiry or a clear_fault would
	e.ecus[0].messages[0].fault = Fault{}
	f := e.due_frames(30)[0]
	assert f.data[0] & 0x0F == u8((frozen + 1) % 16), 'the first recovered frame repeated the frozen counter'
}

// The response path needs the same freeze recovery as the cyclic one: recovery was added to
// due_frames only, so a protected response repeated the frozen counter once after the fault
// ended and the receiver saw one more stall.
fn test_response_counter_resumes_cleanly_after_a_freeze() {
	mut resp := faulted_msg()
	resp.id = 0x102
	mut ecu := SimEcu{
		name:     'N'
		messages: [SimMessage{
			msg:       resp
			period_ms: 0
			e2e:       E2e{ counter: 'AliveCounter', crc: 'CRC', profile: 'crc8_j1850' }
			fault:     Fault{ kind: .freeze_ctr }
		}]
		rules: [ResponseRule{ req_id: 0x101, resp_id: 0x102, byte_index: 0, add: 1 }]
	}
	mut e := Engine{ ecus: [ecu] }
	req := transport.CanFrame{ id: 0x101, data: []u8{len: 8} }
	e.on_frame(req)
	e.on_frame(req)
	frozen := e.ecus[0].messages[0].last_e2e

	e.ecus[0].messages[0].fault = Fault{} // cleared or expired
	out := e.on_frame(req)
	assert out.len == 1
	assert out[0].data[0] & 0x0F == u8((frozen + 1) % 16), 'the recovered response repeated the frozen counter'
}

// An out_of_range target can sit beyond the echoed request's length. set_raw silently skips
// out-of-bounds bits, so the response went out unchanged while the fault reported itself armed.
fn test_faulted_response_is_sized_to_its_message() {
	mut resp := faulted_msg() // dlc 8, Speed at bits 8..23
	resp.id = 0x102
	mut ecu := SimEcu{
		name:     'N'
		messages: [SimMessage{
			msg:       resp
			period_ms: 0
			fault:     Fault{ kind: .out_of_range, signal: 'Speed' }
		}]
		rules: [ResponseRule{ req_id: 0x101, resp_id: 0x102, byte_index: 0, add: 1 }]
	}
	mut e := Engine{ ecus: [ecu] }
	// a 2-byte request: Speed's bits lie past the echoed length
	out := e.on_frame(transport.CanFrame{ id: 0x101, data: [u8(0), 0] })
	assert out.len == 1
	assert out[0].data.len == 8, 'a faulted response must carry its own layout, got ${out[0].data.len}'
	raw := u64(out[0].data[1]) | (u64(out[0].data[2]) << 8)
	assert raw == 0xFFFF, 'the range violation must actually be written'
}

// Freezing must repeat the LAST transmitted value immediately. Advancing once more first meant
// the receiver saw a valid step before the stall — and a timed freeze spanning a single frame
// changed nothing at all.
fn test_freeze_repeats_immediately_after_normal_traffic() {
	mut e := protected_engine(Fault{})
	a := e.due_frames(0)[0].data[0] & 0x0F
	b := e.due_frames(10)[0].data[0] & 0x0F
	assert b == a + 1, 'normal traffic must advance'

	e.ecus[0].messages[0].fault = Fault{ kind: .freeze_ctr }
	c := e.due_frames(20)[0].data[0] & 0x0F
	assert c == b, 'the FIRST frozen frame must repeat the last value, got ${c} after ${b}'

	e.ecus[0].messages[0].fault = Fault{}
	d := e.due_frames(30)[0].data[0] & 0x0F
	assert d == b + 1, 'recovery must advance exactly one step'
}

// A rebuild mid-freeze kept only the NEXT counter, so the frozen value was lost and the frame
// after recovery repeated it.
fn test_freeze_survives_an_engine_rebuild() {
	mut cache := map[string]int{}
	mut e := protected_engine(Fault{ kind: .freeze_ctr })
	e.due_frames(0)
	e.due_frames(10)
	frozen := e.ecus[0].messages[0].last_e2e
	e.save_counters(mut cache)

	mut fresh := protected_engine(Fault{})
	fresh.restore_counters(cache)
	f := fresh.due_frames(20)[0].data[0] & 0x0F
	assert f == u8((frozen + 1) % 16), 'after a rebuild, recovery repeated the frozen counter'
}
