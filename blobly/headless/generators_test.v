module headless

import os
import time
import blobly.j1939
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
      - name: Far
        id: "0x102"
        data: "01"
        bus: inproc:HGENFAR
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
	assert gs.map(it.name) == ['Ping', 'Raw', 'Lost', 'Far']
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

// a script reads a generator's signals back, takes one off its list and changes a raw payload,
// and is told when the bus has taken a frame built after its last edit
fn test_a_script_reads_signals_unsets_one_and_sets_raw_data() {
	mut r, mut bus := gen_run()!
	defer {
		bus.close()
		r.stop()
	}
	gs := r.generators()
	ping, raw := sim.gen_find(gs, 'Ping')!, sim.gen_find(gs, 'Raw')!
	assert gs[ping].applied && gs[raw].applied, 'nothing edited, yet not applied'
	assert gs[raw].data == [u8(1), 2] && gs[ping].data.len == 0

	sigs := r.gen_signals(ping)!
	assert sigs.len == 1 && sigs[0].name == 'ReqCode' && sigs[0].value == 1 && sigs[0].wave.typ == ''
	r.gen_source(ping, 'ReqCode', project.GenCfg{ typ: 'counter', start: 5, modulo: 16 })!
	src := r.gen_signals(ping)!
	assert src.len == 1 && src[0].wave.typ == 'counter' && src[0].wave.start == 5
		&& src[0].value == 1
	assert !r.gen_info(ping)!.applied, 'an edit not yet sent reads as applied'
	r.gen_fire(ping, 0)!
	assert r.gen_info(ping)!.applied
	assert next_of(mut bus, 0x101, 1000)?.data[0] == 5

	// unset: the signal carries the template again, and is no longer listed
	r.gen_unset(ping, 'ReqCode')!
	assert r.gen_signals(ping)!.len == 0
	r.gen_fire(ping, 0)!
	assert next_of(mut bus, 0x101, 1000)?.data[0] == 0
	if _ := r.gen_unset(ping, 'ReqCode') {
		assert false, 'a signal not listed was unset'
	} else {
		assert err.msg().contains('lists no signal')
	}

	// a raw payload, on the cyclic generator: once applied, the last frame queued carries it
	r.gen_data(raw, [u8(9), 8, 7])!
	assert r.gen_info(raw)!.data == [u8(9), 8, 7]
	t0 := time.ticks()
	for !r.gen_info(raw)!.applied {
		assert time.ticks() - t0 < 1000, 'the new payload never went out'
		time.sleep(2 * time.millisecond)
	}
	mut last := []u8{}
	for {
		f := bus.recv(0) or { break }
		if f.id == 0x321 {
			last = f.data.clone()
		}
	}
	assert last == [u8(9), 8, 7]
	assert r.gen_signals(raw)!.len == 0

	// refusals: a raw generator has no signals to unset, a message one no bytes, and a classic
	// wire carries 8
	mut refused := []string{}
	r.gen_unset(raw, 'X') or { refused << err.msg() }
	r.gen_data(ping, [u8(1)]) or { refused << err.msg() }
	r.gen_data(raw, []u8{len: 9}) or { refused << err.msg() }
	assert refused.len == 3 && refused[0].contains('raw frame') && refused[1].contains('signals')
		&& refused[2].contains('at most 8'), refused.str()
	assert r.gen_info(raw)!.data == [u8(9), 8, 7], 'a refused payload replaced the last'
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
	// an answer the loop gave is read whenever its caller looks, without waiting
	assert late.given() == none
	late.reply <- Answer{
		at: 50
	}
	a := late.given() or { panic('the answer given was not read') }
	assert a.at == 50 && a.why == ''
}

// a fire held up by its wire's open (a driver that stalls) ends when the run stops, and its frame
// is never sent once the open returns; a start after an open failed is refused, not left running
fn test_a_stop_ends_a_fire_its_open_holds_up() {
	mut r, mut own := gen_run()!
	own.close()
	mut bus := transport.open('inproc:HGENFAR')!
	defer {
		bus.close()
	}
	release := chan bool{cap: 1}
	r.gen_opener = fn [release] (iface string) !transport.Bus {
		_ := <-release
		return transport.open(iface)
	}
	far := sim.gen_find(r.generators(), 'Far')!
	stopped := chan bool{cap: 1}
	spawn fn [mut r, stopped] () {
		time.sleep(100 * time.millisecond)
		r.stop()
		stopped <- true
	}()
	t0 := time.ticks()
	mut why := ''
	r.gen_fire(far, 0) or {
		assert kind_of(err) == .stopped, err.msg()
		why = err.msg()
	}
	assert why.contains('nothing was sent'), 'the fire did not end with the stop: "${why}"'
	assert time.ticks() - t0 < 1000, 'the fire outlived the stop'
	release <- true
	_ := <-stopped
	assert next_of(mut bus, 0x102, 200) == none, 'a fire the stop ended went out'
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
	far := sim.gen_find(r.generators(), 'Far')!
	mut why := []string{}
	r.gen_fire(far, 0) or { why << err.msg() }
	r.gen_start(far, 50) or { why << err.msg() }
	assert why.len == 2 && why[0].contains('no such device') && why[1].contains('cannot send'), why.str()
	assert !r.generators()[far].running
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

// fires that timed out while the open held the loop up hold no place in its queue
fn test_fires_given_up_on_free_their_place() {
	mut r, mut own := gen_run()!
	own.close()
	mut bus := transport.open('inproc:HGENFAR')!
	defer {
		bus.close()
		r.stop()
	}
	release := chan bool{cap: 1}
	r.gen_opener = fn [release] (iface string) !transport.Bus {
		_ := <-release
		return transport.open(iface)
	}
	far := sim.gen_find(r.generators(), 'Far')!
	mut timeouts := 0
	for _ in 0 .. fires_waiting + 1 {
		r.gen_fire(far, time.sys_mono_now() + 20 * 1_000_000) or {
			assert kind_of(err) == .timeout && err.msg().contains('nothing was sent'), err.msg()
			timeouts++
		}
	}
	assert timeouts == fires_waiting + 1
	spawn fn [release] () {
		time.sleep(50 * time.millisecond)
		release <- true
	}()
	r.gen_fire(far, 0)!
	f := next_of(mut bus, 0x102, 500) or { panic('the fire did not go out') }
	assert f.data[0] == 1
	assert next_of(mut bus, 0x102, 100) == none, 'a fire given up on went out'
}

// a cyclic frame the wire refuses is said once and kept as the generator's note
fn test_a_cyclic_generator_whose_frames_are_refused_says_why() {
	dir := os.join_path(os.vtmp_dir(), 'headless_gen_long_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'long.blobnet')
	os.write_file(path, 'project:
  name: long
  version: 8
channels:
  - name: G1
    type: can
    interface: inproc:HGENLONG
    senders:
      - name: Long
        id: "0x321"
        data: 01 02 03 04 05 06 07 08 09
        trigger: cyclic
        cycle_ms: 10
')!
	mut said := &[]string{}
	proj := load(path, Options{})!
	mut r := start(proj, path, Options{
		err: fn [mut said] (s string) {
			said << s
		}
	})!
	time.sleep(100 * time.millisecond)
	g := r.generators()[0]
	r.stop()
	assert g.sent == 0
	assert g.note.contains('not a classic CAN frame'), g.note
	assert said.filter(it.contains('generator "Long"')).len == 1, said.str()
}

// A generator of a J1939 message past eight bytes sends its BAM, which a listener rejoins whole.
fn test_a_j1939_generator_sends_its_bam() {
	dir := os.join_path(os.vtmp_dir(), 'headless_gen_bam_${os.getpid()}')
	os.mkdir_all(dir)!
	path := os.join_path(dir, 'bam.blobnet')
	os.write_file(path, 'project:
  name: bam
  version: 8
channels:
  - name: J
    type: can
    interface: inproc:HGEN_BAM
    databases:
      - ${os.join_path(@VMODROOT, 'dbc', 'j1939_demo.dbc')}
    senders:
      - name: Body
        message: BodyStatus
        trigger: manual
        signals:
          - { name: Tail, value: 66 }
')!
	mut r := start(load(path, Options{})!, path, Options{})!
	mut bus := transport.open('inproc:HGEN_BAM')!
	defer {
		bus.close()
		r.stop()
	}
	r.gen_fire(0, 0)!
	mut rj := j1939.Reassembler{}
	mut done := []j1939.Assembled{}
	t0 := time.ticks()
	for done.len == 0 && time.ticks() - t0 < 1000 {
		f := bus.recv(20) or { continue }
		ev := rj.feed(f, f64(time.ticks() - t0))
		assert ev.faults.len == 0
		done << ev.done
	}
	assert done.len == 1 && done[0].pgn == 0xFF10 && done[0].sa == 0x21
	assert done[0].data.len == 20 && done[0].data[19] == 66
	assert r.generators()[0].sent == 1
}
