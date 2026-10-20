module script

import time
import sync.stdatomic
import blobly.candb
import blobly.transport

// Said is what a script logged, for a test to read numbers back out of Lua.
struct Said {
mut:
	lines []string
}

fn (s Said) num(prefix string) int {
	for l in s.lines {
		if l.starts_with(prefix) {
			return l.all_after(prefix).trim_space().int()
		}
	}
	return -1
}

fn events_env(names []string, ifaces []string) (&Env, &Said) {
	mut chans := []ChanInfo{}
	for i, n in names {
		chans << ChanInfo{
			name:  n
			iface: ifaces[i]
			db:    candb.Database{}
		}
	}
	mut env := new_env(chans) or { panic(err) }
	mut said := &Said{}
	env.on_output = fn [mut said] (s string) {
		said.lines << s
	}
	return env, said
}

// send_n sends from a handle of its own; the caller opens the script's handles first, so no frame
// is sent before the script listens
fn send_n(iface string, id u32, n int, gap_ms int) {
	mut bus := transport.open(iface) or { panic(err) }
	for i in 0 .. n {
		bus.send(transport.CanFrame{ id: id, data: [u8(i)] }) or {}
		time.sleep(gap_ms * time.millisecond)
	}
	bus.close()
}

// THE MODEL. run() is driven against Lua fakes of the four primitives it looks up as globals —
// __now_ms (synthetic time), __wait_frame and __bus_recv (scripted arrivals on two channels),
// __bus_health (a scripted ladder) — over seeded random scenarios: slow handlers, nested run(),
// bus.recv inside a handler, health handlers registered late, timers whose callbacks are slow or
// run() themselves. It asserts:
//   A1 every frame taken off a channel is delivered exactly once, in arrival order per channel,
//      and when no callback ran to the deadline, every frame that arrived by it was delivered;
//   A2 run(d) started at t0 returns by t0 + d, or by the end of an event taken up by then — a
//      frame (all its handlers), a timer, one health handler;
//   A3 no wait runs past a timer that is due and not running (the budget is computed after the
//      callbacks), and run() never spins without time moving;
//   A4 a health handler is told only known states, never the same one twice running, and each
//      one the newest sample of its channel — never an older one a nested run() overtook;
//   A5 a timer is never fired inside its own callback;
//   A6 a timer stays on its grid: its next due time is its first plus whole periods, and later
//      than when it fired.
const model_src = r'
local s = SEED
local function rnd(n) s = (s * 1103515245 + 12345) % 2147483648; return s % n end

local t = 0
__now_ms = function() return t end
__listen = function(ch) end

local chans = { "A", "B" }
local arrivals = { A = {}, B = {} }
local all = {}
local seq = 0
local horizon = 300
for _, ch in ipairs(chans) do
  local at = rnd(20)
  while at < horizon do
    seq = seq + 1
    local a = { at = at, seq = seq, ch = ch }
    arrivals[ch][#arrivals[ch] + 1] = a
    all[#all + 1] = a
    at = at + 1 + rnd(25)
  end
end
local states = { "", "ok", "error warning", "ERROR-PASSIVE", "BUS-OFF" }
local rungs = { A = {}, B = {} }
for _, ch in ipairs(chans) do
  local at = 0
  while at < horizon * 2 do
    rungs[ch][#rungs[ch] + 1] = { at = at, s = states[rnd(#states) + 1] }
    at = at + 20 + rnd(120)
  end
end
local polls, latest = {}, {}
__bus_health = function(ch)
  local cur = ""
  for _, r in ipairs(rungs[ch]) do
    if r.at <= t then cur = r.s end
  end
  polls[#polls + 1] = { ch = ch, s = cur }
  latest[ch] = #polls
  return cur
end

local delivered, last, popped, ndelivered = {}, { A = 0, B = 0 }, 0, 0
local function take(ch, upto)
  local q = arrivals[ch]
  if #q > 0 and q[1].at <= upto then
    local a = table.remove(q, 1)
    if a.at > t then t = a.at end
    popped = popped + 1
    return a
  end
  return nil
end
local function deliver(ch, sq)
  if delivered[sq] then error("A1: frame " .. sq .. " delivered twice") end
  if sq <= last[ch] then error("A1: frame " .. sq .. " out of order on " .. ch) end
  delivered[sq] = true
  last[ch] = sq
  ndelivered = ndelivered + 1
end
local spins = 0
__wait_frame = function(ms, ...)
  spins = spins + 1
  if spins > 200000 then error("A3: run() spins without time moving") end
  for _, tm in ipairs(__timers) do
    if not tm.active then
      local room = tm.due - t
      if room < 0 then room = 0 end
      if ms > room then error("A3: a wait of " .. ms .. " past a timer due in " .. room) end
    end
  end
  local best, bch = nil, nil
  for _, ch in ipairs({ ... }) do
    local q = arrivals[ch]
    if #q > 0 and q[1].at <= t + ms and (best == nil or q[1].at < best) then
      best = q[1].at
      bch = ch
    end
  end
  if bch == nil then
    t = t + ms
    return nil
  end
  local a = take(bch, t + ms)
  return bch, a.seq, false, tostring(a.seq)
end
__bus_recv = function(ch, timeout)
  local a = take(ch, t + timeout)
  if a == nil then
    t = t + timeout
    return nil
  end
  return a.seq, false, tostring(a.seq)
end

local spans = {}
local depth = 0
local function add_health(ch)
  local rec = { last_idx = 0, last_s = nil }
  on_health(ch, function(st)
    local idx = latest[ch]
    if st == "" then error("A4: told unknown") end
    if st == rec.last_s then error("A4: told " .. st .. " twice running") end
    if polls[idx].s ~= st then error("A4: told " .. st .. " while the newest sample says " .. polls[idx].s) end
    if idx <= rec.last_idx then error("A4: told an older sample") end
    rec.last_idx = idx
    rec.last_s = st
    local start = t
    if depth == 0 then
      local k = rnd(4)
      if k == 0 then
        t = t + rnd(30)
      elseif k == 1 then
        depth = depth + 1
        run(1 + rnd(20))
        depth = depth - 1
      end
    end
    spans[#spans + 1] = { start, t }
  end)
end
local late = 0
local function behave()
  if depth > 0 then return end
  local k = rnd(10)
  if k == 0 then
    t = t + 1 + rnd(40)
  elseif k == 1 then
    depth = depth + 1
    run(1 + rnd(15))
    depth = depth - 1
  elseif k == 2 then
    local ch = chans[rnd(2) + 1]
    local f = bus.recv(ch, rnd(10))
    if f then deliver(ch, f.id) end
  elseif k == 3 and late < 2 then
    late = late + 1
    add_health(chans[rnd(2) + 1])
  end
end
local event_start = {}
for _, ch in ipairs(chans) do
  on_message(ch, nil, function(f)
    event_start[f.id] = t
    deliver(ch, f.id)
    behave()
    spans[#spans + 1] = { event_start[f.id], t }
  end)
  if rnd(2) == 0 then
    on_message(ch, nil, function(f)
      if depth == 0 and rnd(4) == 0 then t = t + rnd(30) end
      spans[#spans + 1] = { event_start[f.id], t }
    end)
  end
end
if rnd(2) == 0 then add_health(chans[rnd(2) + 1]) end
if rnd(3) == 0 then add_health(chans[rnd(2) + 1]) end
for i = 1, rnd(3) do
  local period = 5 + rnd(60)
  local rec = { active = false }
  local first = t + period
  local fired = false
  on_timer(period, function()
    local entry = rec.entry
    if rec.active then error("A5: a timer fired inside its own callback") end
    if not fired and t < first then error("A5: a timer fired before it was due") end
    if (entry.due - first) % period ~= 0 or entry.due <= t then
      error("A6: next due " .. entry.due .. " is off the grid of " .. first .. "+" .. period .. "k or not after " .. t)
    end
    fired = true
    rec.active = true
    local st = t
    if depth == 0 then
      if rnd(3) == 0 then
        t = t + rnd(2 * period)
      elseif rnd(3) == 0 then
        depth = depth + 1
        run(rnd(period))
        depth = depth - 1
      end
    end
    spans[#spans + 1] = { st, t }
    rec.active = false
  end)
  rec.entry = __timers[#__timers]
end

local t0 = t
local d = 50 + rnd(200)
run(d)
local bound, reached = t0 + d, false
for _, sp in ipairs(spans) do
  if sp[1] <= t0 + d and sp[2] > bound then bound = sp[2] end
  if sp[1] <= t0 + d and sp[2] >= t0 + d then reached = true end
end
if t > bound then error("A2: run(" .. d .. ") from " .. t0 .. " returned at " .. t .. ", bound " .. bound) end
if popped ~= ndelivered then error("A1: " .. popped .. " frames taken, " .. ndelivered .. " delivered") end
-- a callback that ran to the deadline leaves what arrived during it queued, for the next reader
if not reached then
  for _, a in ipairs(all) do
    if a.at <= t0 + d and not delivered[a.seq] then error("A1: frame " .. a.seq .. " at " .. a.at .. " never delivered") end
  end
end
'

fn test_model_of_run() {
	for seed in 1 .. 400 {
		mut env, _ := events_env(['A', 'B'], ['inproc:MODEL_A', 'inproc:MODEL_B'])
		env.run_source('SEED = ${seed}\n' + model_src) or {
			env.close()
			assert false, 'seed ${seed}: ${err}'
			return
		}
		env.close()
	}
}

// Frames on two listened channels each reach their handlers.
fn test_run_dispatches_frames_from_two_channels() {
	mut env, said := events_env(['CAN1', 'CAN2'], ['inproc:EV_A', 'inproc:EV_B'])
	defer { env.close() }
	env.bus_for('CAN1')!
	env.bus_for('CAN2')!
	a := spawn send_n('inproc:EV_A', 0x100, 40, 1)
	b := spawn send_n('inproc:EV_B', 0x200, 40, 1)
	env.run_source('
		local na, nb, other = 0, 0, 0
		on_message("CAN1", 0x100, function(f) na = na + 1 end)
		on_message("CAN2", nil, function(f) if f.id == 0x200 then nb = nb + 1 else other = other + 1 end end)
		run(400)
		log("na " .. na)
		log("nb " .. nb)
		log("other " .. other)
	')!
	a.wait()
	b.wait()
	assert said.num('na') == 40, said.lines.str()
	assert said.num('nb') == 40, said.lines.str()
	assert said.num('other') == 0
}

// What run() dispatched is consumed: a later expect gets the frame that arrives after run(), not
// one run() already handled.
fn test_run_consumes_what_it_dispatched() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_F'])
	defer { env.close() }
	env.bus_for('CAN1')!
	mut tx := transport.open('inproc:EV_F')!
	defer { tx.close() }
	for i in 0 .. 5 {
		tx.send(transport.CanFrame{ id: 0x700, data: [u8(i)] })!
	}
	env.run_source('
		__n = 0
		on_message("CAN1", 0x700, function(f) __n = __n + 1 end)
		run(100)
		log("during " .. __n)
	')!
	tx.send(transport.CanFrame{ id: 0x700, data: [u8(99)] })!
	env.run_source('
		local f = expect("CAN1", 0x700, 500)
		log("after " .. string.byte(f.data, 1))
	')!
	assert said.num('during') == 5, said.lines.str()
	assert said.num('after') == 99, 'expect got a frame run() had dispatched: ${said.lines}'
}

// A channel only a health handler names is not read where its ladder needs no reader: what
// arrives there during run() is left for the next reader.
fn test_on_health_alone_does_not_consume_where_health_is_polled() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_V'])
	defer { env.close() }
	env.bus_for('CAN1')!
	mut tx := transport.open('inproc:EV_V')!
	defer { tx.close() }
	tx.send(transport.CanFrame{ id: 0x55 })!
	env.run_source('
		on_health("CAN1", function(s) end)
		run(50)
		local f = bus.recv("CAN1", 200)
		log("left " .. (f and f.id or -1))
	')!
	assert said.num('left') == 0x55, said.lines.str()
}

// run(math.huge) waits a second at a time, not one infinite wait the binding reads as 0 (a busy
// poll): with nothing to wake it but a frame, it makes a handful of waits.
fn test_an_unbounded_run_waits_rather_than_spins() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_W'])
	defer { env.close() }
	env.bus_for('CAN1')!
	t := spawn fn () {
		mut bus := transport.open('inproc:EV_W') or { panic(err) }
		time.sleep(150 * time.millisecond)
		bus.send(transport.CanFrame{ id: 0x66 }) or {}
		bus.close()
	}()
	env.run_source('
		local waits = 0
		local real = __wait_frame
		__wait_frame = function(ms, ...)
			waits = waits + 1
			return real(ms, ...)
		end
		on_message("CAN1", nil, function(f) error("stop") end)
		local ok = pcall(run, math.huge)
		__wait_frame = real
		log("ended " .. tostring(ok))
		log("waits " .. waits)
	')!
	t.wait()
	assert said.lines.contains('ended false'), said.lines.str()
	assert said.num('waits') < 50, 'run(math.huge) polled ${said.num('waits')} times'
}

// What the script sends itself is never heard back as received.
fn test_own_frames_are_not_received() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_G'])
	defer { env.close() }
	env.run_source('
		local rx = 0
		on_message("CAN1", nil, function(f) rx = rx + 1 end)
		on_timer(5, function() bus.send("CAN1", 0x124, "") end)
		run(100)
		log("rx " .. rx)
	')!
	assert said.num('rx') == 0, said.lines.str()
}

// bus.recv inside a handler reads the same handle: it gets the next frame, and run() dispatches
// the rest — every frame exactly once.
fn test_recv_inside_a_handler_takes_the_next_frame() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_J'])
	defer { env.close() }
	env.bus_for('CAN1')!
	t := spawn send_n('inproc:EV_J', 0x10, 6, 10)
	env.run_source('
		local seen = {}
		on_message("CAN1", nil, function(f)
			seen[#seen + 1] = string.byte(f.data, 1)
			if #seen == 1 then
				local g = bus.recv("CAN1", 100)
				seen[#seen + 1] = string.byte(g.data, 1)
			end
		end)
		run(200)
		log("seen " .. table.concat(seen, ","))
	')!
	t.wait()
	assert said.lines.contains('seen 0,1,2,3,4,5'), said.lines.str()
}

// A run() inside a handler does not stop the outer one.
fn test_nested_run_keeps_the_outer_running() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_K'])
	defer { env.close() }
	env.bus_for('CAN1')!
	t := spawn send_n('inproc:EV_K', 0x20, 10, 5)
	env.run_source('
		local n = 0
		on_message("CAN1", nil, function(f)
			n = n + 1
			run(5)
		end)
		run(200)
		log("n " .. n)
	')!
	t.wait()
	assert said.num('n') == 10, said.lines.str()
}

// A run() suspended in a coroutine holds nothing: the environment closes however much traffic
// arrives after it.
fn test_close_with_a_run_suspended_in_a_coroutine() {
	mut env, _ := events_env(['CAN1'], ['inproc:EV_L'])
	env.bus_for('CAN1')!
	t := spawn send_n('inproc:EV_L', 0x30, 5000, 0)
	env.run_source('
		local co = coroutine.create(function()
			on_message("CAN1", nil, function(f) coroutine.yield() end)
			run(1000)
		end)
		coroutine.resume(co)
	')!
	t.wait()
	done := chan bool{cap: 1}
	spawn fn [mut env, done] () {
		env.close()
		done <- true
	}()
	closed := select {
		_ := <-done {
			true
		}
		5 * time.second {
			false
		}
	}
	assert closed, 'close did not return'
}

// Ladder is a bus whose health the test moves.
@[heap]
struct Rung {
mut:
	h i64
}

@[heap]
struct Ladder {
mut:
	rung  &Rung
	polls int
	// steps: the state from the n-th health() call on, by call count, so a test needs no clock
	steps []transport.BusHealth
}

fn (mut b Ladder) send(frame transport.CanFrame) ! {}

fn (mut b Ladder) recv(timeout_ms int) !transport.CanFrame {
	time.sleep(time.Duration(i64(if timeout_ms > 5 { 5 } else { timeout_ms }) * time.millisecond))
	return error('timeout')
}

fn (mut b Ladder) close() {}

fn (mut b Ladder) health() transport.BusHealth {
	b.polls++
	if b.steps.len > 0 {
		return b.steps[if b.polls - 1 < b.steps.len { b.polls - 1 } else { b.steps.len - 1 }]
	}
	return unsafe { transport.BusHealth(int(stdatomic.load_i64(&b.rung.h))) }
}

fn (mut b Ladder) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut b Ladder) reconcile_silence(_ bool) ! {}

fn ladder_env(rung &Rung, steps []transport.BusHealth) (&Env, &Said) {
	mut env, said := events_env(['CAN1'], ['ladder'])
	env.opener = fn [rung, steps] (iface string, _ string) !transport.Bus {
		return &Ladder{
			rung:  rung
			steps: steps
		}
	}
	return env, said
}

fn test_on_health_reports_every_transition() {
	rung := &Rung{}
	mut env, said := ladder_env(rung, [transport.BusHealth.ok, .ok, .unknown, .bus_off, .bus_off,
		.ok])
	defer { env.close() }
	env.run_source('
		local seen = {}
		on_health("CAN1", function(s) seen[#seen + 1] = s end)
		sleep_ms(30) -- work between registering and run(): the first rung is still reported
		run(750)
		log("seen " .. table.concat(seen, ","))
	')!
	assert said.lines.contains('seen ok,BUS-OFF,ok'), said.lines.str()
}

// A health handler registered after an earlier run() read the channel hears the current rung.
fn test_a_late_health_handler_hears_the_current_rung() {
	rung := &Rung{
		h: i64(transport.BusHealth.bus_off)
	}
	mut env, said := ladder_env(rung, [])
	defer { env.close() }
	env.run_source('
		local first, late = {}, {}
		on_health("CAN1", function(s) first[#first + 1] = s end)
		run(150)
		on_health("CAN1", function(s) late[#late + 1] = s end)
		run(150)
		log("first " .. table.concat(first, ","))
		log("late " .. table.concat(late, ","))
	')!
	assert said.lines.contains('first BUS-OFF'), said.lines.str()
	assert said.lines.contains('late BUS-OFF'), 'a handler registered after another was told: ${said.lines}'
}

// A software bus has no controller: bus.health is "", and on_health never fires.
fn test_health_of_a_software_bus_is_unknown() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_E'])
	defer { env.close() }
	env.run_source('
		local fired = 0
		on_health("CAN1", function(s) fired = fired + 1 end)
		run(150)
		log("health [" .. bus.health("CAN1") .. "]")
		log("fired " .. fired)
	')!
	assert said.lines.contains('health []')
	assert said.num('fired') == 0
}

// wait_frame finds a frame on the second of two channels.
fn test_wait_frame_reads_every_channel() {
	mut env, _ := events_env(['CAN1', 'CAN2'], ['inproc:WF_A', 'inproc:WF_B'])
	defer { env.close() }
	env.bus_for('CAN1')!
	env.bus_for('CAN2')!
	mut tx := transport.open('inproc:WF_B')!
	tx.send(transport.CanFrame{ id: 0x55 })!
	tx.close()
	name, f := env.wait_frame(['CAN1', 'CAN2'], 200, 100 * time.microsecond) or {
		assert false, 'nothing came'
		return
	}
	assert name == 'CAN2' && f.id == 0x55
}

// With both channels flooded, successive waits alternate: one cannot starve the other.
fn test_wait_frame_takes_turns() {
	mut env, _ := events_env(['CAN1', 'CAN2'], ['inproc:WF_C', 'inproc:WF_D'])
	defer { env.close() }
	env.bus_for('CAN1')!
	env.bus_for('CAN2')!
	for iface in ['inproc:WF_C', 'inproc:WF_D'] {
		mut tx := transport.open(iface)!
		for i in 0 .. 10 {
			tx.send(transport.CanFrame{ id: u32(i) })!
		}
		tx.close()
	}
	mut order := []string{}
	for _ in 0 .. 8 {
		name, _ := env.wait_frame(['CAN1', 'CAN2'], 0, 100 * time.microsecond) or { break }
		order << name
	}
	assert order == ['CAN1', 'CAN2', 'CAN1', 'CAN2', 'CAN1', 'CAN2', 'CAN1', 'CAN2']
}

// A quiet wait on several channels ends at its timeout, give or take a slice.
fn test_wait_frame_times_out() {
	mut env, _ := events_env(['CAN1', 'CAN2'], ['inproc:WF_E', 'inproc:WF_F'])
	defer { env.close() }
	t0 := time.ticks()
	if _, _ := env.wait_frame(['CAN1', 'CAN2'], 50, 100 * time.microsecond) {
		assert false, 'a frame from nowhere'
	}
	el := time.ticks() - t0
	assert el >= 50 && el < 1000, 'waited ${el} ms for 50'
}

// Closed is a bus that answers every receive with an error at once.
@[heap]
struct Closed {
mut:
	recvs int
}

fn (mut b Closed) send(frame transport.CanFrame) ! {}

fn (mut b Closed) recv(timeout_ms int) !transport.CanFrame {
	b.recvs++
	return error('bus is closed')
}

fn (mut b Closed) close() {}

fn (mut b Closed) health() transport.BusHealth {
	return .unknown
}

fn (mut b Closed) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut b Closed) reconcile_silence(_ bool) ! {}

// A bus that fails at once is not spun on, and not given up on for the rest of the wait.
fn test_wait_frame_rests_on_a_failing_bus() {
	mut env, _ := events_env(['CAN1'], ['closed'])
	defer { env.close() }
	mut closed := &Closed{}
	env.opener = fn [closed] (iface string, _ string) !transport.Bus {
		return closed
	}
	t0 := time.ticks()
	if _, _ := env.wait_frame(['CAN1'], 1000, 100 * time.microsecond) {
		assert false
	}
	el := time.ticks() - t0
	assert closed.recvs == 1
	assert el >= 15 && el < 500, 'rested ${el} ms: neither a spin nor the whole wait'
}

// Late is a bus whose one frame becomes readable at a set time.
@[heap]
struct Late {
mut:
	ready_at i64
	taken    bool
}

fn (mut b Late) send(frame transport.CanFrame) ! {}

fn (mut b Late) recv(timeout_ms int) !transport.CanFrame {
	if !b.taken && time.ticks() >= b.ready_at {
		b.taken = true
		return transport.CanFrame{
			id: 0x77
		}
	}
	return error('timeout')
}

fn (mut b Late) close() {}

fn (mut b Late) health() transport.BusHealth {
	return .unknown
}

fn (mut b Late) diagnostics() transport.BusDiagnostics {
	return transport.BusDiagnostics{}
}

fn (mut b Late) reconcile_silence(_ bool) ! {}

// A frame that becomes readable during the last slice of a wait on several channels is left on
// its handle: nothing is taken off one after the deadline.
fn test_wait_frame_takes_nothing_after_its_deadline() {
	mut env, _ := events_env(['CAN1', 'CAN2'], ['late', 'late2'])
	defer { env.close() }
	t0 := time.ticks()
	mut late := &Late{
		ready_at: t0 + 20 // the deadline: the look after the slice that crosses it would take it
	}
	quiet := &Late{
		ready_at: t0 + 1_000_000
	}
	env.opener = fn [late, quiet] (iface string, _ string) !transport.Bus {
		return if iface == 'late' { late } else { quiet }
	}
	if name, _ := env.wait_frame(['CAN1', 'CAN2'], 20, 7 * time.millisecond) {
		assert false, 'a frame on ${name} taken after the deadline'
	}
	time.sleep(10 * time.millisecond)
	assert !late.taken, 'the frame was read off its handle'
}

// Two health handlers on one channel, the first nesting run() while the state moves: the second is
// told the newer state once, never the older sample afterwards (a false recovery).
fn test_health_after_a_nested_run_is_not_an_older_sample() {
	rung := &Rung{}
	mut env, said := ladder_env(rung, [transport.BusHealth.ok, .bus_off])
	defer { env.close() }
	env.run_source('
		local a, b, nested = {}, {}, false
		on_health("CAN1", function(s)
			a[#a + 1] = s
			if not nested then
				nested = true
				run(150)
			end
		end)
		on_health("CAN1", function(s) b[#b + 1] = s end)
		run(350)
		log("b " .. table.concat(b, ","))
	')!
	assert said.lines.contains('b BUS-OFF'), said.lines.str()
}

// A health handler that runs past the deadline ends run(): the next one is not started.
fn test_no_health_handler_starts_past_the_deadline() {
	rung := &Rung{
		h: i64(transport.BusHealth.ok)
	}
	mut env, said := ladder_env(rung, [])
	defer { env.close() }
	env.run_source('
		local second = 0
		on_health("CAN1", function(s) sleep_ms(60) end)
		on_health("CAN1", function(s) second = second + 1 end)
		run(20)
		log("second " .. second)
	')!
	assert said.num('second') == 0, said.lines.str()
}

// A period that is not a positive number is refused where the timer is registered: zero could
// never move its grid, and run() would not return.
fn test_on_timer_refuses_a_period_that_is_not_positive() {
	for period in ['0', '-5', '"10"'] {
		mut env, _ := events_env(['CAN1'], ['inproc:EV_T'])
		if _ := env.run_source('on_timer(${period}, function() end)') {
			env.close()
			assert false, 'period ${period} was accepted'
			return
		} else {
			assert err.msg().contains('positive number'), err.msg()
		}
		env.close()
	}
}

// A fractional period is waited in whole milliseconds rounded up, never as a busy poll.
fn test_a_fractional_period_does_not_spin() {
	mut env, said := events_env(['CAN1'], ['inproc:EV_U'])
	defer { env.close() }
	env.run_source('
		local fires, waits = 0, 0
		local real = __wait_frame
		__wait_frame = function(ms, ...)
			waits = waits + 1
			return real(ms, ...)
		end
		on_message("CAN1", nil, function(f) end)
		on_timer(2.5, function() fires = fires + 1 end)
		run(100)
		__wait_frame = real
		log("fires " .. fires)
		log("waits " .. waits)
	')!
	assert said.num('fires') >= 20, said.lines.str()
	assert said.num('waits') < 500, 'run() polled ${said.num('waits')} times in 100 ms'
}
