module headless

import os
import time
import blobly.candb
import blobly.cyclic
import blobly.j1939
import blobly.transport

// wire_tp_test.v — a long J1939 message on a wire's loop holds no other entry back: a 1785-byte
// BAM (255 packets, 50 ms apart) or a slow RTS/CTS connection runs beside a 10 ms cyclic
// generator on the same wire, and the cyclic one keeps its period.

const wire_tp_dbc = 'VERSION ""

NS_ :

BS_:

BU_: Body Tool

BO_ 2566856738 Long: 1785 Body
 SG_ Tail : 14272|8@1+ (1,0) [0|255] "" Tool

BO_ 2565813027 Conn: 1785 Body
 SG_ Last : 14272|8@1+ (1,0) [0|255] "" Tool

BA_DEF_ BO_ "VFrameFormat" ENUM "StandardCAN","ExtendedCAN","reserved","J1939PG";
BA_DEF_DEF_ "VFrameFormat" "J1939PG";
'

// the most a 10 ms cyclic generator's frames may be apart while a transfer runs beside it, and
// the least share of its frames that must arrive — loose for a loaded runner; a blocked loop
// sends none for the whole transfer
const fast_gap_max_ms = 100

// wire_tp_run starts a project on `iface` with a 10 ms raw generator (0x100) and, when `long`, a
// generator of the 1785-byte BAM message on a long cycle, so it sends once at the start.
fn wire_tp_run(iface string, long bool) !(&Run, string) {
	dir := os.join_path(os.vtmp_dir(), 'headless_wire_tp_${os.getpid()}_${iface.all_after(':')}')
	os.mkdir_all(dir)!
	dbc := os.join_path(dir, 'tp.dbc')
	os.write_file(dbc, wire_tp_dbc)!
	long_gen := if long {
		'      - name: Long
        message: Long
        trigger: cyclic
        cycle_ms: 60000
        signals:
          - { name: Tail, value: 90 }
'
	} else {
		''
	}
	path := os.join_path(dir, 'tp.blobnet')
	os.write_file(path, 'project:
  name: wire_tp
  version: 8
channels:
  - name: W
    type: can
    interface: ${iface}
    databases:
      - ${dbc}
    senders:
      - name: Fast
        id: "0x100"
        data: "01"
        trigger: cyclic
        cycle_ms: 10
${long_gen}')!
	return start(load(path, Options{})!, path, Options{})!, dbc
}

// Heard is what a reader saw of the wire for a while: the 10 ms generator's arrival times (ms on
// the monotonic clock) and the transport frames.
struct Heard {
mut:
	fast []u64
	tp   []transport.CanFrame
}

// listen reads `bus` for `ms`, or until `enough` says it has what it waits for.
fn listen(mut bus transport.Bus, ms u64, enough fn (h &Heard) bool) Heard {
	mut h := Heard{}
	until := time.sys_mono_now() / 1_000_000 + ms
	for time.sys_mono_now() / 1_000_000 < until && !enough(&h) {
		f := bus.recv(5) or { continue }
		if f.id == 0x100 && !f.extended {
			h.fast << time.sys_mono_now() / 1_000_000
		} else if f.extended {
			p := j1939.pgn(f.id)
			if p == j1939.pgn_tp_cm || p == j1939.pgn_tp_dt {
				h.tp << f
			}
		}
	}
	return h
}

// widest is the widest gap between the generator's frames, and how many came.
fn (h Heard) widest() u64 {
	mut most := u64(0)
	for i in 1 .. h.fast.len {
		if h.fast[i] - h.fast[i - 1] > most {
			most = h.fast[i] - h.fast[i - 1]
		}
	}
	return most
}

fn test_a_bam_generator_holds_no_cyclic_generator_back() {
	mut r, _ := wire_tp_run('inproc:HWTP_BAM', true)!
	mut bus := transport.open('inproc:HWTP_BAM')!
	defer {
		bus.close()
		r.stop()
	}
	h := listen(mut bus, 1200, fn (_ &Heard) bool {
		return false
	})
	dts := h.tp.filter(j1939.pgn(it.id) == j1939.pgn_tp_dt)
	assert dts.len >= 10, 'the BAM goes on: ${dts.len} packets'
	assert h.fast.len >= 50, 'the 10 ms generator: ${h.fast.len} frames in 1.2 s'
	assert h.widest() <= fast_gap_max_ms, 'its frames ${h.widest()} ms apart beside the BAM'
	gs := r.generators()
	assert gs[1].name == 'Long' && gs[1].sent == 0, 'the BAM is not whole yet'
	// the run's stop ends the BAM in progress at once
	t0 := time.ticks()
	r.stop()
	assert time.ticks() - t0 < 1000
	assert released()
}

// SlowPeer answers RTS/CTS connections to 0x33 on its bus, each answer held `hold_ms`.
@[heap]
struct SlowPeer {
	hold_ms int
mut:
	bus   transport.Bus
	stop    bool
	acked   int
	aborted int // aborts heard from the originator
}

fn (mut p SlowPeer) serve() {
	mut rsp := j1939.Responder{
		addresses: [u8(0x33)]
	}
	for !p.stop {
		f := p.bus.recv(5) or { continue }
		if f.extended && j1939.pgn(f.id) == j1939.pgn_tp_cm && f.data[0] == j1939.cm_abort {
			p.aborted++
		}
		out := rsp.feed(f, f64(time.ticks()))
		if out.len > 0 {
			time.sleep(p.hold_ms * time.millisecond)
		}
		for a in out {
			p.bus.send(a) or {}
			if a.data[0] == j1939.cm_eom_ack {
				p.acked++
			}
		}
	}
}

fn test_a_connection_sender_holds_no_cyclic_generator_back() {
	mut r, dbc := wire_tp_run('inproc:HWTP_CONN', false)!
	mut peer := &SlowPeer{
		hold_ms: 20
		bus:     transport.open('inproc:HWTP_CONN')!
	}
	mut bus := transport.open('inproc:HWTP_CONN')!
	defer {
		peer.stop = true
		bus.close()
		r.stop()
	}
	t := spawn peer.serve()
	db := candb.load_dbc_file(dbc)!
	msg := db.message_named('Conn') or { panic('no Conn') }
	mut s := r.start_cyclic(cyclic.Target{
		iface: 'inproc:HWTP_CONN'
		open:  fn () !transport.Bus {
			return transport.open('inproc:HWTP_CONN')
		}
	}, cyclic.Spec{
		by_message: true
		message:    msg
		values:     {
			'Last': 7
		}
		period_ms:  60000
	})!
	// 32 windows, each CTS held 20 ms: the connection takes the better part of a second
	h := listen(mut bus, 4000, fn [mut s] (_ &Heard) bool {
		return s.info().sent > 0 || s.info().failed > 0
	})
	info := s.info()
	assert info.sent == 1 && info.failed == 0, info.error
	assert peer.acked == 1
	dts := h.tp.filter(j1939.pgn(it.id) == j1939.pgn_tp_dt)
	assert dts.len == 255, 'every packet once: ${dts.len}'
	assert h.fast.len >= 30, 'the 10 ms generator: ${h.fast.len} frames'
	assert h.widest() <= fast_gap_max_ms, 'its frames ${h.widest()} ms apart beside the connection'
	peer.stop = true
	t.wait()
	peer.bus.close()
}

// A sender stopped while its connection runs ends it with an abort, and its stop returns at once.
fn test_a_sender_stopped_mid_connection_aborts_it() {
	mut r, dbc := wire_tp_run('inproc:HWTP_ABORT', false)!
	mut peer := &SlowPeer{
		hold_ms: 50
		bus:     transport.open('inproc:HWTP_ABORT')!
	}
	defer {
		peer.stop = true
		r.stop()
	}
	t := spawn peer.serve()
	db := candb.load_dbc_file(dbc)!
	msg := db.message_named('Conn') or { panic('no Conn') }
	mut s := r.start_cyclic(cyclic.Target{
		iface: 'inproc:HWTP_ABORT'
		open:  fn () !transport.Bus {
			return transport.open('inproc:HWTP_ABORT')
		}
	}, cyclic.Spec{
		by_message: true
		message:    msg
		period_ms:  60000
	})!
	time.sleep(200 * time.millisecond)
	t0 := time.ticks()
	assert s.stop()
	assert time.ticks() - t0 < 500
	time.sleep(100 * time.millisecond)
	assert s.info().sent == 0
	assert peer.aborted == 1
	peer.stop = true
	t.wait()
	peer.bus.close()
}
