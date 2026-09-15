module main

import player

// A player releases a due batch before the driver accepts it. Keep the unsent
// suffix when a receive gate refuses a frame, including the final batch after
// the player's timeline has reached .finished.
struct ReplayPending {
mut:
	next   int
	paused bool
}

fn (mut b ReplayPending) commands(mut cmd player.Commands, count int, state player.State) {
	if cmd.seek >= 0 {
		b.next = count // a seek explicitly replaces the pending position
		b.paused = false
		return
	}
	if b.next >= count {
		return
	}
	if cmd.state == .paused {
		b.paused = true
	}
	if cmd.state == .playing {
		b.paused = false
		// Resume the undelivered final batch, not a new pass from the beginning.
		if state == .finished {
			cmd.state = .stopped
		}
	}
}

fn (b ReplayPending) visible_state(count int, state player.State) player.State {
	if b.next < count && state == .finished {
		return if b.paused { player.State.paused } else { player.State.playing }
	}
	return state
}
