module diaghold

import rand

// A MODEL OF THE HOLDER, driving the real decision functions of this module through random
// interleavings of what the GUI, the tools and the ECU do. One tick is one stop slice. The
// holder here is the GUI's diag_holder reduced to its decisions: blocked work asks `cancels`
// every tick, the look handles `pending` commands and asks `release`, presses pass
// `press_refusal`, a keep-alive's outcome is `keepalive_verdict`, and a tool waits on
// `tool_may_start`. What it checks is the set of promises the GUI makes about them.

// ticks within which a cancelled work ends, a tool starts and a stopped holder exits: the
// carrier notices its token within a slice, abandons the wait, and the holder's next look (its
// select times out every 50 ms, two and a half slices) handles the command or exits
const bound = 5

enum Work {
	idle
	opening
	exchanging
	keepalive
}

enum Ecu {
	answers
	open_blocks // TCP connect or routing activation never completes
	pends // every request answered 0x78, for ever
}

struct MHolder {
mut:
	gen       u64
	handled   u64
	held      string
	work      Work
	work_key  string
	left      int // ticks until the work completes; -1: never
	queue     []string
	session   u8
	last_tx   i64
	exited    bool
	cancel_at int = -1 // tick the token first said cancelled while working
	dead_at   int = -1 // tick its run ended
	// what the model itself expects of a command, independent of the functions under test: by
	// tick `drop_by`, nothing but `drop_keep` is held or worked on (-1: no expectation)
	drop_by   int = -1
	drop_keep string
}

struct MTool {
mut:
	cmd   Ticket
	since int
	on    bool
}

struct World {
mut:
	tick       int
	clock_ms   i64 // a slice per tick, and a quiet stretch now and then so keep-alives fall due
	running    bool
	run_gen    u64
	holder_gen u64
	cmds       Commands
	released   Mark
	holders    []MHolder
	tools      []MTool
	busy       bool
	sel        string
	panel_open bool = true
	ecu        Ecu
	fail       string
}

fn (w &World) alive() int {
	return w.holders.filter(!it.exited).len
}

fn (w &World) tools_running() int {
	return w.tools.len
}

fn (mut w World) check(cond bool, what string) {
	if !cond && w.fail == '' {
		w.fail = 'tick ${w.tick}: ${what}'
	}
}

// ---- the GUI side ----

fn (mut w World) press(key string) {
	if press_refusal(w.running, w.busy, w.tools_running()) != '' {
		return
	}
	if w.holder_gen != w.run_gen {
		w.holder_gen = w.run_gen
		w.holders << MHolder{
			gen: w.run_gen
		}
	}
	w.busy = true
	for mut h in w.holders {
		if h.gen == w.holder_gen && !h.exited {
			h.queue << key
			h.drop_by = -1 // the operator asked for more, after the command
		}
	}
}

fn (mut w World) command(why Release, keep string) {
	w.cmds.issue(w.holder_gen, why, keep)
	w.expect_drop(keep)
}

fn (mut w World) expect_drop(keep string) {
	for mut h in w.holders {
		if h.gen == w.holder_gen && !h.exited && h.drop_by < 0 {
			h.drop_by = w.tick + bound
			h.drop_keep = keep
		} else if h.gen == w.holder_gen && !h.exited && h.drop_keep != '' {
			// a release that keeps nothing reaches further than a target change; a later target
			// change replaces an earlier one — either way the deadline runs from now
			h.drop_by = w.tick + bound
			h.drop_keep = keep
		}
	}
}

fn (mut w World) select_target(key string) {
	if key != w.sel {
		w.sel = key
		w.command(.deselected, key)
	}
}

fn (mut w World) tool_begin() {
	w.tools << MTool{
		cmd:   w.cmds.issue(w.holder_gen, .tool, '')
		since: w.tick
	}
	w.expect_drop('')
}

fn (mut w World) tool_end() {
	for i, t in w.tools {
		if t.on {
			w.tools.delete(i)
			return
		}
	}
}

// ---- the holder ----

fn (mut w World) step_holder(i int) {
	mut h := w.holders[i]
	defer {
		w.holders[i] = h
	}
	if h.exited {
		return
	}
	live := w.running && w.run_gen == h.gen
	if !live && h.dead_at < 0 {
		h.dead_at = w.tick
	}
	if h.work != .idle {
		if w.cmds.cancels(h.gen, h.handled, live, h.work_key) {
			// noticed at the carrier's next stop poll, a slice after the trigger at most
			if h.cancel_at < 0 {
				h.cancel_at = w.tick
				return
			}
			// abandoned: the carrier's wait ended with the token, and the holder lets go
			if h.work != .keepalive {
				w.busy = false
			}
			h.work = .idle
			h.held = ''
			h.cancel_at = -1
			return
		}
		if h.left > 0 {
			h.left--
		}
		if h.left == 0 {
			w.finish(mut h)
		}
		return
	}
	// the look
	mut command := Release.keep
	if w.cmds.pending(h.gen, h.handled) {
		w.check(w.cmds.gen == h.gen, 'gen ${h.gen} handled a command of gen ${w.cmds.gen}')
		command = w.cmds.releases(h.handled, h.held)
		h.handled = w.cmds.seq
	}
	r := release(View{
		held_key:     h.held
		selected_key: w.sel
		panel_open:   w.panel_open
		run_live:     live
		command:      command
		tool_running: w.tools_running() > 0
	})
	if r != .keep {
		h.held = ''
		h.session = 0
	}
	w.check(command == .keep || h.held == '', 'a command that releases left the connection held')
	w.released = Mark{h.gen, h.handled}
	if !live {
		h.exited = true
		if w.holder_gen == h.gen {
			w.holder_gen = 0
		}
		if h.queue.len > 0 {
			h.queue.clear()
			w.busy = false
		}
		return
	}
	if keepalive_due(h.held != '', h.session, h.last_tx, w.clock_ms) {
		h.work = .keepalive
		h.work_key = h.held
		h.left = 1 // bounded: one slice, whatever the ECU does
		return
	}
	if h.queue.len > 0 {
		key := h.queue[0]
		h.queue.delete(0)
		h.drop_by = -1 // a press taken after the command is the operator's newer word
		if press_refusal(true, false, w.tools_running()) != '' {
			w.busy = false
			return
		}
		h.work_key = key
		if h.held != key {
			h.held = ''
			h.work = .opening
			h.left = if w.ecu == .open_blocks { -1 } else { 1 }
		} else {
			h.work = .exchanging
			h.left = if w.ecu == .pends { -1 } else { 1 }
		}
	}
}

fn (mut w World) finish(mut h MHolder) {
	match h.work {
		.opening {
			h.held = h.work_key
			h.work = .exchanging
			h.left = if w.ecu == .pends { -1 } else { 1 }
		}
		.exchanging {
			h.work = .idle
			h.session = 0x03 // every request here may as well be a session switch
			h.last_tx = w.clock_ms
			w.busy = false
		}
		.keepalive {
			h.work = .idle
			h.last_tx = w.clock_ms
			// answered 0x78: then silent past the bound (an error), or answered late (no error)
			v := if w.ecu == .pends {
				keepalive_verdict(rand.intn(2) or { 0 } == 0, false, 1)
			} else {
				keepalive_verdict(false, false, 0)
			}
			if v != .ok {
				h.held = ''
				h.session = 0
			}
			w.check(w.ecu != .pends || h.held == '', 'a keep-alive answered 0x78 kept the connection')
		}
		.idle {}
	}
}

// ---- the tools ----

fn (mut w World) step_tools() {
	for mut t in w.tools {
		if t.on {
			continue
		}
		if tool_may_start(w.alive(), w.holder_gen, w.released, t.cmd) {
			owned := w.holders.any(!it.exited && (it.held != '' || it.work != .idle))
			w.check(!owned, 'a tool started while a holder owns the entity')
			t.on = true
		} else {
			w.check(w.tick - t.since <= bound, 'a tool waited ${w.tick - t.since} ticks for the release')
		}
	}
}

// ---- invariants that need time ----

fn (mut w World) check_bounds() {
	for mut h in w.holders {
		if h.exited {
			continue
		}
		live := w.running && w.run_gen == h.gen
		if h.work != .idle && w.cmds.cancels(h.gen, h.handled, live, h.work_key) {
			if h.cancel_at < 0 {
				h.cancel_at = w.tick
			}
			w.check(w.tick - h.cancel_at <= bound, 'gen ${h.gen} still working ${w.tick - h.cancel_at} ticks after its cancel')
		}
		if h.drop_by >= 0 && w.tick > h.drop_by {
			keeps := (h.held == '' || h.held == h.drop_keep)
				&& (h.work == .idle || h.work_key == h.drop_keep)
			w.check(keeps, 'gen ${h.gen} still holds or works on ${h.held}/${h.work_key} after a command keeping "${h.drop_keep}"')
			h.drop_by = -1
		}
		if h.dead_at >= 0 {
			w.check(w.tick - h.dead_at <= bound, 'gen ${h.gen} outlived its run by ${w.tick - h.dead_at} ticks')
		}
		if h.work == .idle && h.held == '' {
			// an idle holder with nothing held has nothing a tool could share
		} else {
			w.check(!w.tools.any(it.on), 'a holder owns the entity while a tool runs')
		}
	}
}

fn (mut w World) event() {
	keys := ['A', 'B']
	match rand.intn(13) or { 0 } {
		0, 1, 2 { w.press(w.sel) } // a press addresses the selected target, as the panel's do
		3 { w.running = false }
		4 {
			if !w.running {
				w.running = true
				w.run_gen++
				w.ecu = unsafe { Ecu(rand.intn(3) or { 0 }) }
			}
		}
		5 { w.tool_begin() }
		6 { w.tool_end() }
		7 { w.command(.disconnect, '') }
		8 { w.select_target(keys[rand.intn(2) or { 0 }]) }
		9 {
			w.panel_open = !w.panel_open
			if !w.panel_open {
				w.command(.panel_closed, '')
			}
		}
		10 { w.ecu = unsafe { Ecu(rand.intn(3) or { 0 }) } }
		11 { w.clock_ms += keepalive_ms }
		else {} // a quiet tick: keep-alives fall due
	}
}

fn run_model(seed u32, steps int) string {
	rand.seed([seed, seed ^ 0x9E3779B9])
	mut w := World{
		running: true
		run_gen: 1
		sel:     'A'
	}
	for t in 0 .. steps {
		w.tick = t
		w.clock_ms += stop_slice_ms
		for _ in 0 .. 1 + (rand.intn(2) or { 0 }) {
			w.event()
		}
		// either side may look first within a slice
		tools_first := rand.intn(2) or { 0 } == 0
		if tools_first {
			w.step_tools()
		}
		for i in 0 .. w.holders.len {
			w.step_holder(i)
		}
		if !tools_first {
			w.step_tools()
		}
		w.check_bounds()
		if w.fail != '' {
			return 'seed ${seed}: ${w.fail}'
		}
	}
	return ''
}

fn test_the_holder_model_keeps_its_promises() {
	for seed in u32(1) .. 3000 {
		f := run_model(seed, 300)
		assert f == '', f
	}
}
