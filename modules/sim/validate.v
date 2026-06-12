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
	if node !in db.nodes {
		warns << 'node "${node}" is not in the DBC (BU_)'
		return warns // signal checks are meaningless without a valid node
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
