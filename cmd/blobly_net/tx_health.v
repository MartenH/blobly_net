module main

import time
import transport

struct TxHealthWatch {
	gen      u64
	busy     bool
	failures int
}

// Only filed transmit taps count. Reading the tap's interface avoids decoding
// its channel/name key, and wire_key folds aliases and bitrate spellings.
fn (app &App) tx_health_targets_locked() map[string]string {
	mut targets := map[string]string{}
	for _, bus in app.tx_buses {
		if bus is TapBus {
			targets[transport.wire_key(bus.iface)] = bus.iface
		}
	}
	for c in app.chans {
		if c.monitorable() && (c.running || c.spawning) {
			targets.delete(transport.wire_key(c.iface))
		}
	}
	return targets
}

// Observe independently of transmit scheduling. A slow or failed receiver does
// not delay sends; faults before it opens may therefore be missed.
fn tx_health_loop(app &App, gen u64) {
	defer { release_run_worker(app) }
	mut a := unsafe { app }
	for {
		a.mu.lock()
		if !a.running || a.run_gen != gen {
			a.mu.unlock()
			return
		}
		mut starts := []string{}
		for wire, iface in a.tx_health_targets_locked() {
			old := a.tx_health_watches[wire] or { TxHealthWatch{} }
			if old.gen == gen && (old.busy || old.failures >= 3) {
				continue
			}
			a.tx_health_watches[wire] = TxHealthWatch{
				gen: gen
				busy: true
				failures: if old.gen == gen { old.failures } else { 0 }
			}
			a.reserve_run_worker_locked()
			starts << iface
		}
		a.mu.unlock()
		for iface in starts {
			spawn tx_health_reader(app, iface, gen)
		}
		for _ in 0 .. 10 {
			time.sleep(100 * time.millisecond)
			a.mu.lock()
			live := a.running && a.run_gen == gen
			a.mu.unlock()
			if !live {
				return
			}
		}
	}
}

fn tx_health_reader(app &App, iface string, gen u64) {
	mut a := unsafe { app }
	wire := transport.wire_key(iface)
	mut failed := false
	defer {
		a.mu.lock()
		if old := a.tx_health_watches[wire] {
			if old.gen == gen {
				a.tx_health_watches[wire] = TxHealthWatch{
					gen: gen
					failures: old.failures + if failed { 1 } else { 0 }
				}
			}
		}
		a.mu.unlock()
		release_run_worker(app)
	}
	a.mu.lock()
	live := a.running && a.run_gen == gen && wire in a.tx_health_targets_locked()
	phys := a.phys_for_locked(iface)
	a.mu.unlock()
	if !live {
		return
	}
	mut bus := transport.open(phys) or {
		failed = true
		notify_gen(app, gen, '${iface}: cannot observe bus health — ${err}')
		return
	}
	defer { bus.close() }
	mut last := transport.BusHealth.unknown
	mut next := i64(0)
	mut next_check := i64(0)
	for {
		if time.ticks() >= next_check {
			next_check = time.ticks() + 200
			a.mu.lock()
			wanted := a.running && a.run_gen == gen && wire in a.tx_health_targets_locked()
			a.mu.unlock()
			if !wanted {
				return
			}
		}
		// SocketCAN error frames and Vector chip-state replies update health in
		// recv. A timeout is normal, and still permits a status poll on a quiet bus.
		bus.recv(200) or {
			if !err.msg().contains('timeout') {
				failed = true
				notify_gen(app, gen, '${iface}: bus-health receive failed — ${err}')
				return
			}
		}
		if time.ticks() >= next {
			next = time.ticks() + 1000
			observed := bus.health()
			if observed != .unknown && observed != last {
				a.report_tx_health(iface, gen, last, observed)
				last = observed
			}
		}
	}
}

fn (mut app App) report_tx_health(iface string, gen u64, from transport.BusHealth, to transport.BusHealth) {
	app.mu.lock()
	live := app.running && app.run_gen == gen && transport.wire_key(iface) in app.tx_health_targets_locked()
	app.mu.unlock()
	if live && to != .unknown && to != from {
		notify_gen(app, gen, health_msg(iface, from, to))
	}
}
