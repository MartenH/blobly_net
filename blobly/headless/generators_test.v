module headless

import os
import time
import blobly.project
import blobly.sim
import blobly.transport

const gen_project = 'project:
  name: generators
  version: 8
channels:
  - name: G1
    type: can
    interface: inproc:HGEN
    databases:
      - DBC
    senders:
      - name: Ping
        message: Request
        trigger: manual
        signals:
          - { name: ReqCode, value: 1 }
      - name: Raw
        id: "0x321"
        data: 01 02
        trigger: cyclic
        cycle_ms: 50
      - name: Lost
        message: NoSuchMessage
'

fn gen_run() !(&Run, transport.Bus) {
	dir := os.join_path(os.vtmp_dir(), 'headless_gen_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'gen.blobnet')
	os.write_file(path, gen_project.replace('DBC', os.join_path(@VMODROOT, 'dbc', 'blobly_net.dbc')))!
	proj := load(path, Options{})!
	r := start(proj, path, Options{})!
	return r, transport.open('inproc:HGEN')!
}

// the next frame of `id` within ms, None when none came
fn next_of(mut bus transport.Bus, id u32, ms int) ?transport.CanFrame {
	until := time.ticks() + ms
	for time.ticks() < until {
		f := bus.recv(20) or { continue }
		if f.id == id {
			return f
		}
	}
	return none
}

fn drain(mut bus transport.Bus) {
	for {
		bus.recv(0) or { return }
	}
}

fn kind_of(err IError) sim.GenErrorKind {
	if err is sim.GenError {
		return err.kind
	}
	return .refused
}

fn test_a_script_fires_edits_and_cycles_the_runs_generators() {
	mut r, mut bus := gen_run()!
	defer {
		bus.close()
		r.stop()
	}
	gs := r.generators()
	assert gs.map(it.name) == ['Ping', 'Raw', 'Lost']
	assert gs[0].id == 0x101 && gs[0].message == 'Request' && !gs[0].running
	assert gs[1].running && gs[1].cycle_ms == 50 && gs[1].target == 'inproc:HGEN'
	assert gs[2].note.contains('not in the channel databases')
	ping, raw := sim.gen_find(gs, 'Ping')!, sim.gen_find(gs, 'G1/Raw')!

	// fire: once, with the generator's values, counted
	r.gen_fire(ping, 0)!
	assert next_of(mut bus, 0x101, 1000)?.data[0] == 1
	assert r.generators()[ping].sent == 1
	r.gen_value(ping, 'ReqCode', 7)!
	r.gen_fire(ping, 0)!
	assert next_of(mut bus, 0x101, 1000)?.data[0] == 7
	assert r.proj.channels[0].senders[0].signals[0].value == 1, 'an edit reached the loaded project'
	// a source counts the frames sent: 2 before, so 12 and 13
	r.gen_source(ping, 'ReqCode', project.GenCfg{ typ: 'counter', start: 10, step: 1, modulo: 256 })!
	r.gen_fire(ping, 0)!
	r.gen_fire(ping, 0)!
	assert next_of(mut bus, 0x101, 1000)?.data[0] == 12
	assert next_of(mut bus, 0x101, 1000)?.data[0] == 13

	// a cyclic generator stops, and starts again on a cycle of its own
	r.gen_stop(raw)!
	time.sleep(80 * time.millisecond)
	drain(mut bus)
	assert next_of(mut bus, 0x321, 200) == none, 'a stopped generator sent'
	r.gen_start(raw, 20)!
	first := next_of(mut bus, 0x321, 500)?
	mut n := 0
	t0 := time.ticks()
	for time.ticks() - t0 < 300 {
		if _ := next_of(mut bus, 0x321, 300 - int(time.ticks() - t0)) {
			n++
		}
	}
	assert first.data == [u8(1), 2]
	assert n >= 5 && n <= 17, '${n} frames in 300 ms at 20 ms'
	r.gen_cycle(raw, 100)!
	assert r.generators()[raw].cycle_ms == 100 && r.generators()[raw].running
	// a start on a slow cycle sends from now; a shorter cycle applies at once
	r.gen_cycle(raw, 1000)!
	time.sleep(30 * time.millisecond)
	drain(mut bus)
	next_of(mut bus, 0x321, 1500) or { assert false, 'no frame at 1000 ms' }
	r.gen_start(raw, 1000)!
	next_of(mut bus, 0x321, 300) or { assert false, 'a start did not send at once' }
	r.gen_cycle(raw, 20)!
	next_of(mut bus, 0x321, 300) or { assert false, 'a shorter cycle waited for the old one' }

	// a manual generator runs cyclically when given a cycle; one with none is refused
	if _ := r.gen_start(ping, 0) {
		assert false, 'a generator with no cycle started'
	} else {
		assert err.msg().contains('no cycle')
	}
	r.gen_start(ping, 30)!
	assert next_of(mut bus, 0x101, 500) != none
	r.gen_stop(ping)!

	// refusals, typed
	mut refused := []string{}
	r.gen_cycle(raw, 0) or { refused << '${kind_of(err)}' }
	r.gen_value(ping, 'Nope', 1) or { refused << '${kind_of(err)}' }
	r.gen_value(raw, 'X', 1) or { refused << '${kind_of(err)}' }
	r.gen_fire(2, 0) or { refused << '${kind_of(err)}' }
	r.gen_fire(9, 0) or { refused << '${kind_of(err)}' }
	r.gen_source(ping, 'ReqCode', project.GenCfg{ typ: 'sawtooth' }) or {
		refused << '${kind_of(err)}'
	}
	assert refused == ['refused'].repeat(6)
	r.stop()
	assert !r.generators()[raw].running, 'a generator of a stopped run reads as running'
	r.gen_fire(ping, 0) or {
		assert kind_of(err) == .stopped, err.msg()
		return
	}
	assert false, 'a stopped run fired'
}

// a fire given up on, or reached past its time, is never sent; one taken is not dropped
fn test_a_fire_given_up_is_not_sent_later() {
	mut f := &Fire{
		until: 100
	}
	assert f.drop() && !f.take(0)
	mut g := &Fire{
		until: 100
	}
	assert g.take(99) && !g.drop()
	// one its loop reaches past its time is not sent, though its caller has not looked yet
	mut late := &Fire{
		until: 100
	}
	assert !late.take(100) && late.drop()
}

// a fire held up by its bus's open (a driver that stalls) ends when the run stops, and its frame
// is never sent once the open returns; a start after an open failed is refused, not left running
fn test_a_stop_ends_a_fire_its_open_holds_up() {
	mut r, mut bus := gen_run()!
	defer {
		bus.close()
	}
	release := chan bool{cap: 1}
	r.gen_opener = fn [release] (iface string) !transport.Bus {
		_ := <-release
		return transport.open(iface)
	}
	ping := sim.gen_find(r.generators(), 'Ping')!
	stopped := chan bool{cap: 1}
	spawn fn [mut r, stopped] () {
		time.sleep(100 * time.millisecond)
		r.stop()
		stopped <- true
	}()
	t0 := time.ticks()
	mut why := ''
	r.gen_fire(ping, 0) or {
		assert kind_of(err) == .stopped, err.msg()
		why = err.msg()
	}
	assert why.contains('nothing was sent'), 'the fire did not end with the stop: "${why}"'
	assert time.ticks() - t0 < 1000, 'the fire outlived the stop'
	release <- true
	_ := <-stopped
	assert next_of(mut bus, 0x101, 200) == none, 'a fire the stop ended went out'
}

fn test_a_start_after_a_failed_open_is_refused() {
	mut r, mut bus := gen_run()!
	defer {
		bus.close()
		r.stop()
	}
	r.gen_opener = fn (iface string) !transport.Bus {
		return error('no such device')
	}
	ping := sim.gen_find(r.generators(), 'Ping')!
	mut why := []string{}
	r.gen_fire(ping, 0) or { why << err.msg() }
	r.gen_start(ping, 50) or { why << err.msg() }
	assert why.len == 2 && why[0].contains('no such device') && why[1].contains('cannot send'), why.str()
	assert !r.generators()[ping].running
}

// what a fire's caller is told, in order: a stop that overtook it (whatever became of the frame),
// a refusal, an answer past the deadline, else success
fn test_a_fire_outcome_is_decided_in_one_order() {
	cases := [
		// why, answered at, stopping -> kind ('' success)
		['', '50', 'false', ''],
		['', '150', 'false', 'timeout'],
		['', '50', 'true', 'stopped'],
		['not sent: listen-only', '50', 'false', 'refused'],
		['not sent: listen-only', '50', 'true', 'stopped'],
		[run_stopped, '50', 'false', 'stopped'],
		['', '100', 'false', ''],
	]
	for c in cases {
		mut got := ''
		fire_outcome('g', Answer{ why: c[0], at: c[1].u64() }, 100, c[2] == 'true') or {
			got = '${kind_of(err)}'
		}
		assert got == c[3], '${c}: ${got}'
	}
}
