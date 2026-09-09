module player

import canlog
import transport

// due_into is due() into a buffer the caller keeps: same entries, same order, cleared first,
// and the buffer's capacity survives, so a steady replay tick allocates nothing for its batch.
fn test_due_into_is_due_into_the_callers_buffer() {
	mut es := []canlog.LogEntry{}
	for i in 0 .. 5 {
		es << canlog.LogEntry{
			t_s:   f64(i)
			iface: 'x'
			frame: transport.CanFrame{
				id: u32(i)
			}
		}
	}
	mut p := new_player_over(es, 1.0, false, 0.0, 4.0)
	p.play(0.0)
	mut q := new_player_over(es, 1.0, false, 0.0, 4.0)
	q.play(0.0)
	mut buf := []canlog.LogEntry{cap: 8}
	stale := buf.data
	for now in [0.0, 1500.0, 1500.0, 4000.0] {
		want := p.due(now)
		q.due_into(now, mut buf)
		assert buf.len == want.len, 'at ${now}'
		for i in 0 .. want.len {
			assert buf[i].frame.id == want[i].frame.id
		}
		assert buf.data == stale, 'the buffer was reallocated at ${now}'
	}
	assert p.state() == q.state()
}
