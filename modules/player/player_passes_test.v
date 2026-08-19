module player

import canlog
import transport

fn two_frames() []canlog.LogEntry {
	return [
		canlog.LogEntry{
			t_s:   0.0
			iface: 'vcan0'
			frame: transport.CanFrame{
				id:   0x100
				data: [u8(1)]
			}
		},
		canlog.LogEntry{
			t_s:   0.1
			iface: 'vcan0'
			frame: transport.CanFrame{
				id:   0x101
				data: [u8(2)]
			}
		},
	]
}

// A non-looping replay that reaches the end has completed ONE pass. It reported
// zero, because only a wrap counted, so the GUI printed "finished (N frames,
// 0 pass(es))" after every ordinary replay -- the case where the number is
// least ambiguous and it was the one the code could not state.
fn test_finished_non_looping_counts_its_pass() {
	mut p := new_player(two_frames(), 1.0, false)
	p.play(0)
	p.due(1000) // well past the end
	assert p.finished()
	assert p.passes() == 1
}

// A looping replay still counts wraps, and gains no phantom extra pass.
fn test_repeat_counts_wraps() {
	mut p := new_player(two_frames(), 1.0, true)
	p.play(0)
	p.due(250) // 0.1 s recording -> at least two wraps
	assert !p.finished()
	assert p.passes() >= 2
}

// An EMPTY recording finishes without claiming to have replayed anything.
fn test_empty_recording_counts_no_pass() {
	mut p := new_player([]canlog.LogEntry{}, 1.0, false)
	p.play(0)
	p.due(1000)
	assert p.finished()
	assert p.passes() == 0
}
