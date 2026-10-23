// E2E on a script's frames: every frame its handle on a channel reads is judged by that
// message's E2E (sim.E2eReader: the channel's verify: entry, else the database's declaration,
// else what a node simulated on its wire stamps), and bus.send_message stamps the declared E2E
// (sim.E2eStamper), each message's counter from 0 for the script's run.
module script

import blobly.lua
import blobly.project
import blobly.sim
import blobly.transport

fn (mut env Env) register_e2e() {
	env.st.register('__e2e_stamp', l_e2e_stamp)
}

// e2e_verdict is the verdict on a frame the script's handle on `name` received, none for one its
// message has no E2E for.
fn (mut env Env) e2e_verdict(name string, f transport.CanFrame) ?string {
	mut r := env.e2e_rx[name] or {
		ci := env.find_chan(name) or { return none }
		c := env.chans[ci]
		r := sim.new_e2e_reader(c.db, env.wire_nodes(c.iface), c.verify)
		env.e2e_rx[name] = r
		r
	}
	v := r.judge(f) or { return none }
	return v.name()
}

// wire_nodes is every node simulated on the wire `iface` reaches, whichever row simulates it:
// what the handle hears from that wire is theirs, as the trace's verifiers take them (rx_loop)
fn (env &Env) wire_nodes(iface string) []project.NodeCfg {
	dest := transport.destination_key(iface)
	mut out := []project.NodeCfg{}
	mut have := map[string]bool{}
	for c in env.chans {
		if transport.destination_key(c.iface) != dest {
			continue
		}
		for n in c.nodes {
			if n.name !in have {
				have[n.name] = true
				out << n
			}
		}
	}
	return out
}

// push_e2e pushes a received frame's verdict, nil where none
fn push_e2e(l lua.State, verdict ?string) {
	if v := verdict {
		l.push_str(v)
	} else {
		l.push_nil()
	}
}

// __e2e_stamp(channel, message, data) -> data with the message's declared E2E stamped (its next
// counter), or as it was where it declares none; an error where its declaration cannot be applied
fn l_e2e_stamp(l lua.State) i32 {
	mut env := env_of(l)
	name := l.arg_str(1)
	ci := env.find_chan(name) or { return l.fail(err.msg()) }
	msg := env.chans[ci].db.message_named(l.arg_str(2)) or {
		return l.fail('unknown message "${l.arg_str(2)}"')
	}
	mut data := l.arg_bytes(3)
	mut st := env.e2e_tx[name] or {
		st := &sim.E2eStamper{}
		env.e2e_tx[name] = st
		st
	}
	st.stamp(msg, mut data) or {
		return l.fail('${err.msg()} (bus.send_message with { e2e = false })')
	}
	l.push_bytes(data)
	return 1
}
