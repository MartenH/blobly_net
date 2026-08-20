module project

// runtime_fingerprint summarises everything a front end derives its RUNTIME VIEW from — the
// channel list, what is attached to each channel, and the simulated nodes on it. Two projects
// with the same fingerprint produce the same channels, databases, simulated ECUs, verifiers and
// replay groups; two with different fingerprints do not.
//
// WHY THIS EXISTS. The GUI keeps a runtime view (its channel array, loaded databases, simulated
// nodes, the Ethernet shell's identity) that is rebuilt from the project. That rebuild can be
// REFUSED — a worker may still be reading the arrays it would replace — and an edit can simply
// not rebuild at all. Either way the view stops describing the project, and anything that acts
// on it then acts on something that is no longer true.
//
// Marking that by hand means every mutation site has to remember, and the ones that forget are
// invisible until something built on them misbehaves: net#121 spent four review rounds finding
// them one at a time, and the last one was a checkbox that wrote the model and marked nothing.
// Comparing a fingerprint taken at the last successful rebuild against the project's current one
// CANNOT be forgotten by a new call site, because no call site is involved. A front end asks the
// question; it never answers it.
//
// EXHAUSTIVE BY CONSTRUCTION. It hashes the struct's own `str()` rather than a hand-written list
// of fields, because a hand-written list is the same forgetting problem one level down — the
// first draft of this function omitted a generator's `amplitude`, and its test caught it. A
// field added to Channel or NodeCfg later is covered with no edit here.
//
// SENDERS ARE THE ONE EXCLUSION. Interactive generators are edited in the runtime view and
// folded back into the project, so including them would report the view as stale immediately
// after it was brought up to date — a false alarm on the one field that legitimately travels in
// the other direction.
pub fn (p Project) runtime_fingerprint() u64 {
	// A copy with senders dropped, so the exclusion is the only thing this function decides.
	mut bare := []Channel{cap: p.channels.len}
	for c in p.channels {
		mut cc := c
		cc.senders = []
		bare << cc
	}
	mut h := fnv_str(u64(0xcbf29ce484222325), p.name)
	return fnv_str(h, bare.str())
}

fn fnv_str(seed u64, s string) u64 {
	mut h := seed
	for b in s.bytes() {
		h ^= u64(b)
		h *= u64(0x100000001b3)
	}
	return h
}
