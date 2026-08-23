module player

import canlog
import transport

// set_repeat's contract is that looping is a PASSIVE flag: it is consulted only when playback
// reaches the end of a pass, so toggling it is never itself an action. These tests pin the four
// cases that follow from that. The one most at risk from a later "helpful" change is the third
// -- arming loop on a finished group is meant to do nothing, and making it restart there would
// look like a fix rather than the regression it is.

// rep_rec builds a 0.2 s recording: frames at 0.0 / 0.1 / 0.2 s carrying ids 1, 2, 3, so an
// emission is identifiable by id. Named apart from player_test.v's rec(): `v test` compiles each
// _test.v on its own, so every file carries its own helpers, and duplicate names would collide
// if they were ever built together.
fn rep_rec() []canlog.LogEntry {
	mut out := []canlog.LogEntry{}
	for i, t in [0.0, 0.1, 0.2] {
		out << canlog.LogEntry{
			t_s:   100.0 + t // absolute base proves only deltas matter
			iface: 'test0'
			frame: transport.CanFrame{
				id:   u32(i + 1)
				data: [u8(i)]
			}
		}
	}
	return out
}

fn rep_ids(es []canlog.LogEntry) []u32 {
	return es.map(it.frame.id)
}

fn test_set_repeat_armed_mid_pass_wraps_at_the_end() {
	mut p := new_player(rep_rec(), 1.0, false)
	p.play(0)
	assert rep_ids(p.due(100)) == [u32(1), 2]
	p.set_repeat(true) // armed while playing: nothing happens now
	assert p.due(150).len == 0 // ... and nothing plays that was not already due
	assert rep_ids(p.due(250)) == [u32(3), 1] // the end arrives, and it wraps
	assert !p.finished()
	assert p.passes() == 1
}

fn test_set_repeat_disarmed_mid_pass_finishes_at_the_end() {
	mut p := new_player(rep_rec(), 1.0, true)
	p.play(0)
	assert rep_ids(p.due(100)) == [u32(1), 2]
	p.set_repeat(false)
	assert rep_ids(p.due(250)) == [u32(3)] // the wrap that would have happened does not
	assert p.finished()
}

fn test_set_repeat_when_finished_does_not_restart() {
	mut p := new_player(rep_rec(), 1.0, false)
	p.play(0)
	assert rep_ids(p.due(250)) == [u32(1), 2, 3]
	assert p.finished()
	p.set_repeat(true) // the end it would have looped at is already behind it
	assert p.due(500).len == 0 // so nothing plays
	assert p.finished() // and it stays finished; only play() moves it again
}

fn test_set_repeat_while_paused_plays_nothing_then_takes_effect_on_resume() {
	mut p := new_player(rep_rec(), 1.0, false)
	p.play(0)
	assert rep_ids(p.due(100)) == [u32(1), 2]
	p.pause(100)
	p.set_repeat(true)
	assert p.due(500).len == 0 // paused: the toggle emits nothing on its own
	p.play(500) // resumes 100 ms into the recording
	assert rep_ids(p.due(650)) == [u32(3), 1] // finishes the pass, then wraps
}

// A Restart is a fresh run, so its pass count starts over. play() already rewound idx and
// elapsed_ms from .finished and left `loops` alone, which only became visible once loop was
// settable at runtime: the panel then labelled a restarted first pass "(loop 2)".
fn test_restart_from_finished_resets_the_pass_count() {
	mut p := new_player(rep_rec(), 1.0, false)
	p.play(0)
	assert rep_ids(p.due(250)) == [u32(1), 2, 3]
	assert p.finished()
	assert p.passes() == 1 // the pass that just ended counts
	p.play(300) // Restart
	assert p.passes() == 0 // ... and the new run starts from zero
	assert rep_ids(p.due(300)) == [u32(1)]
}
