module sim

import candb

// validate_node checks a configured simulated ECU against the network database:
//   1. is `node` a known transmitter (declared in the DBC `BU_`)?
//   2. is each generator signal actually one of that node's message signals?
// Returns human-readable warnings ([] = all good). These are exactly the mismatches
// build_configured_ecu / build_sim_nodes silently ignore, so typos surface instead
// of producing a node that quietly sends nothing.
pub fn validate_node(db candb.Database, node string, gen_signals []string) []string {
	mut warns := []string{}
	// What matters is whether the node OWNS MESSAGES, not whether it is listed in BU_.
	//   - a DBC may name senders on its BO_ entries and carry no BU_ at all: messages_from()
	//     finds those and the node transmits, so a BU_-only check called it invalid;
	//   - and a BU_ entry that sends nothing produces an ECU with no messages, which a
	//     BU_-only check called fine while it sat silent.
	// Callers that configure raw response rules suppress this — see validate_cfg.
	if db.messages_from(node).len == 0 {
		warns << 'node "${node}" sends no message in the DBC — it will transmit nothing'
		return warns // signal checks are meaningless without messages
	}
	mut sigset := map[string]bool{}
	for m in db.messages_from(node) {
		for s in m.signals {
			sigset[s.name] = true
		}
	}
	for sg in gen_signals {
		if sg.len > 0 && sg !in sigset {
			warns << 'signal "${sg}" is not in ${node}\'s messages'
		}
	}
	return warns
}
