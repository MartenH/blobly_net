module player

import canlog
import transport

// due_with_schedule hands back the time each entry was due at ON THE PASS IT WAS RELEASED FROM.
// A stalled caller reading a looped recording gets one batch spanning several laps, and the
// player's base has moved on by then: scoring against due_at_ms would put every earlier lap's
// entries a lap or more early. This is the one place that schedule survives the wrap.
fn test_due_with_schedule_keeps_each_entrys_own_pass() {
	mut es := []canlog.LogEntry{}
	for i in 0 .. 2 {
		es << canlog.LogEntry{
			t_s:   f64(i)
			iface: 'x'
			frame: transport.CanFrame{
				id: u32(i)
			}
		}
	}
	// a 2 s recording looping at 1x; a stall of 5 s crosses two full laps
	mut p := new_player_over(es, 1.0, true, 0.0, 2.0)
	p.play(0.0)
	batch, dues := p.due_with_schedule(5000.0)
	assert batch.len == 6, 'three laps owed: ${batch.len}'
	assert dues == [0.0, 1000.0, 2000.0, 3000.0, 4000.0, 5000.0]
	// and the lateness a caller computes from them is the truth, not a lap short
	assert 5000.0 - dues[0] == 5000.0
	assert 5000.0 - dues[4] == 1000.0
	// due() is the same release without the schedule
	mut q := new_player_over(es, 1.0, true, 0.0, 2.0)
	q.play(0.0)
	assert q.due(5000.0).len == 6
}
