module player

import canlog
import transport

// due_at_ms is the ONE spelling of when an entry plays. due() must release an entry exactly
// there, next_due_ms() must name it, and — since the GUI's cadence probe measures against it —
// it must be in playback-clock ms and scale with speed, which the GUI's own spelling did not.
fn test_due_at_ms_is_when_due_releases_the_entry() {
	mut es := []canlog.LogEntry{}
	for i in 0 .. 3 {
		es << canlog.LogEntry{
			t_s:   10.0 + f64(i)
			iface: 'x'
			frame: transport.CanFrame{
				id: 1
			}
		}
	}
	mut p := new_player_over(es, 2.0, false, 10.0, 12.0)
	p.play(100.0) // the playback clock reads 100 ms when play begins
	// the second entry sits 1 s into the recording; at 2x that is 500 ms after the first
	assert p.due_at_ms(es[0]) == 100.0
	assert p.due_at_ms(es[1]) == 600.0
	assert p.due(500.0).len == 1, 'only the first entry is due before 600'
	assert p.due(600.0).len == 1, 'the second is released exactly at its due_at_ms'
	assert p.next_due_ms() or { -1.0 } == p.due_at_ms(es[2])
}
