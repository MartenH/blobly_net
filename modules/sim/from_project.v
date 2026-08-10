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
			// The DBC decides whether the response is a standard or an extended frame — it is
			// a property of the message, not of the rule, and ResponseCfg has nowhere to say
			// it. Leaving this at false made a protected EXTENDED response unfindable once the
			// lookup started matching on ext: no protection applied, and the reply emitted as
			// a standard frame. Unresolved ids keep false, which is the correct default for a
			// rule that names no DBC message at all.
			resp_ext: resp_is_extended(db, cfg, r.response)
		}
	}
	return build_protected_ecu(db, cfg.name, gens, rules, prot)
}

// validate_cfg reports everything in a node's configuration that will NOT take effect: an
// unknown node or generator signal, and any protection that matches nothing.
//
// ONE entry point, because the two halves were inconsistent: protection typos were reported
// while generator typos were not — `validate_node` existed for exactly that and had zero
// callers, so its warnings were computed nowhere. A single function means a consumer cannot
// wire up half the checking.
pub fn validate_cfg(db candb.Database, cfg project.NodeCfg) []string {
	mut sigs := []string{}
	for g in cfg.signals {
		sigs << g.signal
	}
	mut warns := []string{}
	// A node with response rules is a legitimate configuration even when the DBC knows nothing
	// about it: the rules carry raw request/response ids and answer them, which is explicitly
	// supported. Reporting "transmits nothing" there presents working behaviour as broken, so
	// the transmitter check only applies when nothing else would make the node do anything.
	if cfg.responses.len == 0 {
		warns << validate_node(db, cfg.name, sigs)
	} else if db.messages_from(cfg.name).len > 0 {
		warns << validate_node(db, cfg.name, sigs) // has messages too: signal names still count
	}
	warns << validate_protection(db, cfg)
	return warns
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
	// A rule whose response id matches BOTH a standard and an extended message: the reply's
	// format, DLC and protection all hinge on which one is chosen.
	for r in cfg.responses {
		mut fmts := map[string]bool{}
		for m in db.messages_from(cfg.name) {
			if m.id == r.response {
				fmts['${m.ext}'] = true
			}
		}
		if fmts.len > 1 {
			// How many of the candidates carry protection decides whether the hint resolves it.
			mut protected_hits := 0
			for m in db.messages_from(cfg.name) {
				if m.id != r.response {
					continue
				}
				for p in cfg.protect {
					if p.message == m.name {
						protected_hits++
					}
				}
			}
			warns << if protected_hits == 1 {
				'responses: id 0x${r.response:X} matches both a standard and an extended message; the protected one is used'
			} else {
				// zero protected candidates, or several: nothing distinguishes them, so the
				// DBC order decides the reply format, DLC, protection layout and counter
				'responses: id 0x${r.response:X} matches both a standard and an extended message and protect: does not single one out — the DBC order decides which is sent; give exactly one of them a protect: entry'
			}
		}
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
		// A multiplexed counter or checksum is only written when its branch is selected, so
		// protection comes and goes with the payload — legal, but never what someone means.
		for sg in m.signals {
			if sg.is_multiplexed && (sg.name == p.counter || sg.name == p.crc) {
				warns << 'protect: "${sg.name}" on ${p.message} is multiplexed — it is only written when its branch is active'
			}
		}
		if p.crc == '' && p.data_id != none {
			// apply() returns before the id is ever read: with no checksum there is nothing to
			// mix it into. It still displays and still serializes, so it reads as configured.
			warns << 'protect: "${p.message}" sets data_id but no crc — the id is not used'
		}
		for sg in m.signals {
			if sg.name == p.crc && sg.length != 8 {
				// every profile returns a u8. A wider field carries zeros in its upper bits, a
				// narrower one truncates the checksum — either way a receiver computing over
				// the DBC-declared width rejects the frame.
				warns << 'protect: checksum "${p.crc}" on ${p.message} is ${sg.length} bits — every supported profile produces 8'
			}
		}
		if p.counter != '' && p.counter == p.crc {
			// apply() writes the counter, then zeroes that field to compute the checksum over
			// it, then writes the checksum there — so the counter is overwritten and the frame
			// goes out with none. Both membership checks pass, which is why this needs saying.
			warns << 'protect: counter and crc are both "${p.counter}" on ${p.message} — the checksum overwrites the counter'
		}
		if p.crc != '' && p.profile !in ['crc8_j1850', 'crc8_autosar', 'sum8', 'xor8'] {
			warns << 'protect: unknown profile "${p.profile}" on ${p.message} — falling back to sum8'
		}
	}
	return warns
}

// resp_is_extended reports the frame format the DBC gives the message with this id among the
// node's own messages. False when nothing matches — a rule may legitimately name an id that is
// not a DBC message.
//
// A standard and an extended message may share a number, and ResponseCfg has no field to say
// which is meant. When one of them is named by a `protect:` entry, that is the answer: you do
// not configure protection for a message you did not intend to send. Otherwise the first match
// wins and validate_cfg reports the ambiguity, rather than silently picking a format that
// decides the reply's DLC and whether protection applies at all.
fn resp_is_extended(db candb.Database, cfg project.NodeCfg, id u32) bool {
	mut protected_names := map[string]bool{}
	for p in cfg.protect {
		protected_names[p.message] = true
	}
	mut first := ?bool(none)
	for m in db.messages_from(cfg.name) {
		if m.id != id {
			continue
		}
		if m.name in protected_names {
			return m.ext
		}
		if first == none {
			first = m.ext
		}
	}
	return first or { false }
}

// attach_protection applies per-message protection to an already-built ECU.
pub fn attach_protection(mut ecu SimEcu, prot map[string]E2e) {
	for i, m in ecu.messages {
		if e := prot[m.msg.name] {
			ecu.messages[i].e2e = e
		}
	}
}
