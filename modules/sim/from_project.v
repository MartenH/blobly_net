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
			data_id: if p.has_data_id { ?u32(p.data_id) } else { none }
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

// validate_protection reports every `protect:` entry that will NOT take effect.
//
// A misspelled or stale message name matches nothing, so attach_protection quietly does
// nothing while the panel still shows the configured count — the simulation then transmits
// ordinary frames that a protected receiver rejects, and the UI insists protection is on.
// That is the worst kind of failure this feature can have: silent, and contradicted by the
// display. Same for a counter or checksum signal that is not in the named message.
pub fn validate_protection(db candb.Database, cfg project.NodeCfg) []string {
	mut warns := []string{}
	mut msgs := map[string]candb.Message{}
	for m in db.messages_from(cfg.name) {
		msgs[m.name] = m
	}
	mut seen := map[string]bool{}
	for p in cfg.protect {
		// Neither field set = nothing to apply. E2e.active() is false, every frame goes out
		// bare, and the panel still counts the entry as protection — so say it plainly. A
		// data_id alone is this case too: an id feeds a checksum that was never requested.
		if p.counter == '' && p.crc == '' {
			warns << 'protect: "${p.message}" sets neither counter nor crc — nothing is protected'
		}
		// The engine keys protection by message, so a second entry for the same message
		// REPLACES the first. Splitting a counter and a checksum across two entries reads
		// perfectly and loses one of them, with both still displayed.
		if p.message in seen {
			warns << 'protect: "${p.message}" appears more than once — only the last entry applies; put counter and crc in ONE entry'
		}
		seen[p.message] = true
		m := msgs[p.message] or {
			warns << 'protect: message "${p.message}" is not sent by ${cfg.name} — protection not applied'
			continue
		}
		mut have := map[string]bool{}
		for sg in m.signals {
			have[sg.name] = true
		}
		if p.counter != '' && p.counter !in have {
			warns << 'protect: counter "${p.counter}" is not a signal of ${p.message}'
		}
		if p.crc != '' && p.crc !in have {
			warns << 'protect: checksum "${p.crc}" is not a signal of ${p.message}'
		}
		if p.crc != '' && p.profile !in ['crc8_j1850', 'crc8_autosar', 'sum8', 'xor8'] {
			warns << 'protect: unknown profile "${p.profile}" on ${p.message} — falling back to sum8'
		}
	}
	return warns
}

// attach_protection applies per-message protection to an already-built ECU.
pub fn attach_protection(mut ecu SimEcu, prot map[string]E2e) {
	for i, m in ecu.messages {
		if e := prot[m.msg.name] {
			ecu.messages[i].e2e = e
		}
	}
}
