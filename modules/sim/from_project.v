// Turning a project's node configuration into a simulation ECU. ONE implementation, in the
// module that owns the engine.
//
// This lived as three byte-identical copies — cmd/blobly_net, cmd/script (the headless runner
// CI and runtests.sh use) and cmd/sim_startup_check — one of which was commented "mirror
// src/main.v". Adding end-to-end protection to the GUI copy alone meant the same project
// transmitted protected frames interactively and unprotected ones under a script, which would
// have invalidated scripted bench results in the least visible way possible.
module sim

import candb
import project

// gen_from_cfg maps a project generator entry onto an engine generator.
pub fn gen_from_cfg(g project.GenCfg) Gen {
	return match g.typ {
		'sine' { gen_sine(g.offset, g.amplitude, g.freq, g.phase) }
		'sawtooth' { gen_sawtooth(g.min, g.max, g.period) }
		'counter' { gen_counter(g.start, g.step, g.modulo) }
		'stepmod' { gen_stepmod(g.period, g.count, g.base) }
		else { gen_const(g.value) }
	}
}

// from_project builds the ECU a NodeCfg describes.
pub fn from_project(db candb.Database, cfg project.NodeCfg) SimEcu {
	mut prot := map[string]E2e{}
	for p in cfg.protect {
		prot[p.message] = E2e{
			counter: p.counter
			crc:     p.crc
			profile: p.profile
			data_id: p.data_id
		}
	}
	// No generators and no response rules: the node has no explicit BEHAVIOUR, so keep the
	// built-in model — which for 'SUT' is the hand-tuned reference with its own generators and
	// request/response rule. Protection is orthogonal to behaviour and is layered on top;
	// treating a protect: block as "this node is configured now" would silently replace the
	// SUT's defaults with a generic DBC-derived ECU merely because someone enabled a checksum.
	if cfg.signals.len == 0 && cfg.responses.len == 0 {
		mut ecu := build_ecu(db, cfg.name)
		attach_protection(mut ecu, prot)
		return ecu
	}
	mut gens := map[string]Gen{}
	for g in cfg.signals {
		gens[g.signal] = gen_from_cfg(g)
	}
	mut rules := []ResponseRule{}
	for r in cfg.responses {
		rules << ResponseRule{
			req_id:     r.request
			resp_id:    r.response
			byte_index: r.byte
			add:        r.add
		}
	}
	return build_protected_ecu(db, cfg.name, gens, rules, prot)
}

// attach_protection applies per-message protection to an already-built ECU.
pub fn attach_protection(mut ecu SimEcu, prot map[string]E2e) {
	for i, m in ecu.messages {
		if e := prot[m.msg.name] {
			ecu.messages[i].e2e = e
		}
	}
}
