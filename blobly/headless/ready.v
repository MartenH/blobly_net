module headless

import time

// ready.v — whether the run's loops are up: each loop start spawns that opens a bus (a row's
// simulated nodes, a UDS node, the default UDS server, a cyclic generator) reports its open
// here, and wait_ready waits until none is still opening. A generator that opens at its first
// fire or start is not one of them.

// LoopState is where a loop's open stands.
pub enum LoopState {
	opening
	up     // its bus is open (a cyclic generator: the bus took its first frame)
	failed // its open failed, or a cyclic generator's frame was refused: `why`
}

// LoopReady is one loop: who it is (`<channel>: simulated nodes`, `<channel>: generator "x"`),
// where its open stands and why it failed.
pub struct LoopReady {
pub:
	name  string
	state LoopState
	why   string
}

// opening registers a loop about to be spawned and returns its index.
fn (mut r Run) opening(name string) int {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	r.ready << LoopReady{
		name: name
	}
	return r.ready.len - 1
}

// loop_is sets loop i's state: up when `why` is '', else failed with `why`.
fn (mut r Run) loop_is(i int, why string) {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if i < 0 || i >= r.ready.len {
		return
	}
	r.ready[i] = LoopReady{
		name:  r.ready[i].name
		state: if why == '' { LoopState.up } else { LoopState.failed }
		why:   why
	}
}

// loops is every loop the run waits for, as it stands now.
pub fn (mut r Run) loops() []LoopReady {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	return r.ready.clone()
}

// wait_ready waits at most timeout_ms (negative: until it happens) for no loop to be opening,
// on the monotonic clock, and returns the loops as they then stand (ready_note reads them).
pub fn (mut r Run) wait_ready(timeout_ms int) []LoopReady {
	until := time.sys_mono_now() + u64(if timeout_ms > 0 { timeout_ms } else { 0 }) * 1_000_000
	for {
		ls := r.loops()
		now := time.sys_mono_now()
		if !ls.any(it.state == .opening) || (timeout_ms >= 0 && now >= until) {
			return ls
		}
		mut step := i64(5) * time.millisecond
		if timeout_ms >= 0 && i64(until - now) < step {
			step = i64(until - now)
		}
		time.sleep(step)
	}
	return []
}

// ready_note is '' when every loop is up, else how many are not and each one's reason, a line
// per loop: `2 of 6 not up:` then `  BusB: simulated nodes: cannot open ...`.
pub fn ready_note(ls []LoopReady) string {
	down := ls.filter(it.state != .up)
	if down.len == 0 {
		return ''
	}
	mut lines := ['${down.len} of ${ls.len} not up:']
	for l in down {
		lines << '  ${l.name}: ${if l.state == .opening { 'still opening' } else { l.why }}'
	}
	return lines.join('\n')
}

// open_failed marks loop i failed with `why` and says so.
fn (mut r Run) open_failed(i int, why string) {
	r.loop_is(i, why)
	r.mu.lock()
	name := r.ready[i].name
	r.mu.unlock()
	r.say('${name}: ${why}')
}
