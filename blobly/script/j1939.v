// J1939 on a script's frames: every frame its handle on a channel reads goes through that
// channel's j1939.Listener — the transport protocol rejoined and the address directory — where the
// wire reads as J1939 (a row on it ticked `j1939:`, a database declaring it) or the script asked
// (any j1939.* call). Completed messages decode by candb.pgn_message_in, the trace's rule, over the
// row's database files, mapped into its merged catalog (pgn_message_in_catalog). Nothing is sent.
module script

import time
import blobly.candb
import blobly.j1939
import blobly.lua
import blobly.transport

fn (mut env Env) register_j1939() {
	env.st.register('__j1939_listen', l_j1939_listen)
	env.st.register('__j1939_wait', l_j1939_wait)
	env.st.register('__j1939_faults', l_j1939_faults)
	env.st.register('__j1939_addresses', l_j1939_addresses)
	env.st.register('__j1939_dropped', l_j1939_dropped)
}

// __j1939_dropped(channel) -> the messages and faults dropped untaken, the queues being full
fn l_j1939_dropped(l lua.State) i32 {
	mut env := env_of(l)
	lis := env.j1939_of(l.arg_str(1)) or { return l.fail(err.msg()) }
	l.push_int(lis.dropped)
	return 1
}

// j1939_says is whether channel `ci`'s wire reads as J1939: the host says so (ChanInfo.j1939, every
// project row on the wire counted), or a channel here on it declares it (j1939.on_wire).
fn (env &Env) j1939_says(ci int) bool {
	keys := env.chans.map(transport.destination_key(it.fault_iface()))
	// each file asked where the host kept them: the merge may hold an undeclared copy of an id
	says := env.chans.map(it.j1939 || it.db.j1939_declared() || it.sources.any(it.j1939_declared()))
	return j1939.on_wire(keys, says, ci)
}

// j1939_saw feeds a frame the script's handle on `name` read to the channel's listener, made at its
// first frame where the wire reads as J1939 (a channel that does not is remembered). On the host's
// clock as it is read, never the frame's placed stamp: the transfer timeouts are this process's
// bookkeeping, as the trace's are, and an empty look expires them by the same clock.
fn (mut env Env) j1939_saw(name string, f transport.CanFrame) {
	mut l := env.j1939_rx[name] or {
		if name in env.j1939_off {
			return
		}
		ci := env.find_chan(name) or { return }
		if !env.j1939_says(ci) {
			env.j1939_off[name] = true
			return
		}
		l := &j1939.Listener{}
		env.j1939_rx[name] = l
		l
	}
	l.feed(f, f64(time.sys_mono_now()) / 1_000_000.0)
}

// j1939_idle times the stalled transfers of `name`'s listener out: its handle had nothing queued.
fn (mut env Env) j1939_idle(name string) {
	if mut l := env.j1939_rx[name] {
		l.idle(f64(time.sys_mono_now()) / 1_000_000.0)
	}
}

// j1939_of is the listener of channel `name`, made if the script had none there (a CAN channel).
fn (mut env Env) j1939_of(name string) !&j1939.Listener {
	env.bus_for(name)!
	if l := env.j1939_rx[name] {
		return l
	}
	l := &j1939.Listener{}
	env.j1939_rx[name] = l
	return l
}

// j1939_read reads channel `name` into its listener `lis` until `deadline` (sys_mono_now), or with
// `until_message` until a completed message waits; a deadline already past is one look. A wait the
// run's deadline cuts is an error (timeout_note).
fn (mut env Env) j1939_read(name string, lis &j1939.Listener, deadline u64, until_message bool) ! {
	mut bus := env.bus_for(name)!
	mut first := true
	for !(until_message && lis.queued() > 0) {
		now := time.sys_mono_now()
		if now >= deadline && !first {
			return
		}
		first = false
		left := if now >= deadline { 0 } else { int((deadline - now) / 1_000_000) }
		f := bus.recv(if left < 100 { left } else { 100 }) or {
			if env.expired() {
				return error(timeout_note)
			}
			if transport.look_was_spent(err) {
				continue
			}
			if err.msg() != 'timeout' {
				return error('j1939: ${name}: ${err.msg()}')
			}
			env.j1939_idle(name)
			if left == 0 {
				// what a whole-millisecond wait cannot ask for is slept, not skipped
				rest := i64(deadline) - i64(time.sys_mono_now())
				if rest > 0 {
					time.sleep(rest * time.nanosecond)
				}
				return
			}
			continue
		}
		env.j1939_saw(name, f)
		_ = env.e2e_verdict(name, f) or { '' } // its message's E2E reader sees every frame the script reads
	}
}

// __j1939_listen(channel): the channel read as J1939 from now on
fn l_j1939_listen(l lua.State) i32 {
	mut env := env_of(l)
	env.j1939_of(l.arg_str(1)) or { return l.fail(err.msg()) }
	return 0
}

// __j1939_wait(channel, timeout_ms, pgn, sa) -> { message, ... }: the completed messages taken,
// oldest first — every one waiting, or up to the first of `pgn` (any, below 0) from `sa` (any,
// below 0), the rest left queued — the channel read until one is taken or the wait has passed; a
// wait of 0 is one look
fn l_j1939_wait(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	ms := env.bounded(l.arg_int(2))
	deadline := time.sys_mono_now() + u64(if ms > 0 { ms } else { 0 }) * 1_000_000
	mut lis := env.j1939_of(name) or { return l.fail(err.msg()) }
	ci := env.find_chan(name) or { return l.fail(err.msg()) }
	ch := env.chans[ci]
	pgn := l.arg_int(3)
	sa := l.arg_int(4)
	any_one := pgn < 0 && sa < 0
	mut got := []j1939.Assembled{}
	mut others := map[string]int{} // what came instead of a match: counted, not kept
	mut order := []string{}
	mut matched := false
	mut first := true
	for {
		for !matched {
			a := lis.next_message() or { break }
			matched = !any_one && (pgn < 0 || i64(a.pgn) == pgn) && (sa < 0 || i64(a.sa) == sa)
			if any_one || matched {
				got << a
			} else {
				k := 'PGN 0x${a.pgn:04X} from SA 0x${a.sa:02X}'
				if k !in others {
					order << k
				}
				others[k]++
			}
		}
		if matched || (any_one && got.len > 0) || (!first && time.sys_mono_now() >= deadline) {
			break
		}
		first = false
		env.j1939_read(name, lis, deadline, true) or {
			if err.msg() == timeout_note {
				return timeout_at(l)
			}
			return l.fail(err.msg())
		}
	}
	l.new_table()
	for i, a in got {
		push_assembled(l, ch, a)
		l.set_index(i + 1)
	}
	l.push_str(order.map(if others[it] > 1 { '${it} (x${others[it]})' } else { it }).join(', '))
	return 2
}

// push_assembled pushes one completed message as a table: pgn, sa, da, priority, bam, data,
// packets, t_ms (its last packet) and t_start_ms, and where the database decodes it name and
// signals, else note (why definitions that disagree decode nothing)
fn push_assembled(l lua.State, ch ChanInfo, a j1939.Assembled) {
	l.new_table()
	l.set_int('pgn', a.pgn)
	l.set_int('sa', a.sa)
	l.set_int('da', a.da)
	l.set_int('priority', a.priority)
	l.set_bool('bam', a.bam)
	l.push_bytes(a.data)
	l.set_field('data')
	l.set_int('packets', a.packets())
	l.set_num('t_ms', a.t_end_ms)
	l.set_num('t_start_ms', a.t_start_ms)
	pm := candb.pgn_message_in_catalog(ch.sources, ch.db, a.pgn, a.sa)
	if pm.found {
		l.set_str('name', pm.msg.name)
		l.new_table()
		for s in pm.msg.active_signals(a.data) {
			l.set_num(s.name, s.physical(a.data))
		}
		l.set_field('signals')
	} else if pm.refused != '' {
		l.set_str('note', pm.refused)
	}
}

// __j1939_faults(channel) -> { { kind, sa, da, pgn (nil where none was announced), detail, text } }:
// the faults since the last call, oldest first
fn l_j1939_faults(l lua.State) i32 {
	mut env := env_of(l)
	mut lis := env.j1939_of(l.arg_str(1)) or { return l.fail(err.msg()) }
	l.new_table()
	mut i := 1
	for {
		f := lis.next_fault() or { break }
		l.new_table()
		l.set_str('kind', f.kind.str())
		l.set_int('sa', f.sa)
		l.set_int('da', f.da)
		if f.announced {
			l.set_int('pgn', f.pgn)
		}
		l.set_str('detail', f.detail)
		l.set_str('text', f.str())
		l.set_index(i)
		i++
	}
	return 1
}

// __j1939_addresses(channel, window_ms) -> { { sa, name = { raw, identity, ... }, t_ms } }: the
// directory by address, after reading the channel for window_ms (0: nothing read)
fn l_j1939_addresses(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	ms := env.bounded_window(l.arg_int(2))
	deadline := time.sys_mono_now() + u64(if ms > 0 { ms } else { 0 }) * 1_000_000
	lis := env.j1939_of(name) or { return l.fail(err.msg()) }
	if ms > 0 {
		env.j1939_read(name, lis, deadline, false) or {
			if err.msg() == timeout_note {
				return timeout_at(l)
			}
			return l.fail(err.msg())
		}
	}
	l.new_table()
	for i, nd in lis.dir.nodes() {
		n := nd.name
		l.new_table()
		l.set_int('sa', nd.sa)
		l.set_num('t_ms', nd.t_ms)
		l.new_table()
		l.set_int('raw', i64(n.raw)) // its 64 bits: negative where bit 63 is set
		l.set_int('identity', n.identity)
		l.set_int('manufacturer', n.manufacturer)
		l.set_int('ecu_instance', n.ecu_instance)
		l.set_int('function_instance', n.function_instance)
		l.set_int('function', n.function)
		if fname := j1939.function_name(n.function) {
			l.set_str('function_name', fname)
		}
		l.set_int('vehicle_system', n.vehicle_system)
		l.set_int('vehicle_system_instance', n.vehicle_system_instance)
		l.set_int('industry_group', n.industry_group)
		l.set_bool('arbitrary_address_capable', n.arbitrary_address_capable)
		l.set_field('name')
		l.set_index(i + 1)
	}
	return 1
}
