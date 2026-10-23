// E2E on the frames a script reads and sends (Lua's bus.*, the C ABI's bus handles): a frame it
// reads is judged by the verifier the trace's verify: uses, and a message it sends by name is
// stamped with what its database declares, as the simulation stamps it (declared_e2e, E2e.apply).
module sim

import blobly.candb
import blobly.project
import blobly.transport

// receive_checks is what a frame received on a row is judged by, per message: the row's verify:
// entry for it, else its database's declaration (declared_e2e). Both are contracts a receiver
// holds a sender to; a node's protect: entry is not, being the simulated sender's own word, which
// may deviate from the declaration on purpose.
pub fn receive_checks(db candb.Database, verify []project.ProtectCfg) VerifySet {
	mut s := verifiers_for(db, [], verify)
	for m in db.messages {
		k := vkey(m.id, m.ext)
		if k in s.by_key {
			continue
		}
		if e := declared_e2e(m) {
			s.by_key[k] = Verifier{
				msg: m
				e2e: e
			}
		}
	}
	return s
}

// unjudged_most bounds the ids a reader remembers as judged by nothing.
const unjudged_most = 4096

// E2eReader judges the frames one reader receives on a row by receive_checks, keeping what each
// message's check carries from frame to frame: its last counter, and when its last valid frame
// came. Its frames in the order received, every frame of a checked id: one it was not given
// reads, at the next, as a counter that skipped.
@[heap]
pub struct E2eReader {
mut:
	set      VerifySet
	dbs      []candb.Database
	unjudged map[string]bool // ids that resolve to no checked message
}

// new_e2e_reader is a reader of a row whose database is `db` and its verify: entries `verify`.
pub fn new_e2e_reader(db candb.Database, verify []project.ProtectCfg) &E2eReader {
	return &E2eReader{
		set: receive_checks(db, verify)
		dbs: [db]
	}
}

// judges is how many messages its frames are judged for; 0, and judge answers none for every one.
pub fn (r &E2eReader) judges() int {
	return r.set.by_key.len
}

// judge is the verdict on a received frame, none for a frame of no checked message or a remote
// frame (no payload). Its time against E2ETimeout is its raw receive stamp (hw_ns in hw_domain),
// not its placement on the host's clock, which an estimate that improves can move between two
// frames; a frame with no stamp is timed only by its reading, and judged on its bytes alone.
pub fn (mut r E2eReader) judge(f transport.CanFrame) ?Violation {
	if f.rtr || r.set.by_key.len == 0 {
		return none
	}
	k := vkey(f.id, f.extended)
	if k in r.unjudged {
		return none
	}
	key := r.set.resolve(r.dbs, f.id, f.extended) or {
		if r.unjudged.len >= unjudged_most {
			r.unjudged.clear()
		}
		r.unjudged[k] = true
		return none
	}
	mut v := r.set.by_key[key] or { return none }
	got := v.check_at(f.data, f.hw_domain, f.hw_ns)
	r.set.by_key[key] = v
	return got
}

// E2eStamper stamps what one sender sends by name with each message's declared E2E, counting
// that message's sends as a simulated sender counts its own: the first carries counter 0.
@[heap]
pub struct E2eStamper {
mut:
	sent map[string]u64
}

// stamp writes `m`'s declared counter and checksum into `data`, its encoded payload, and counts
// the send; false, `data` unchanged, when m declares no E2E, and an error when it declares one that
// cannot be applied (declared_problem), which sent unstamped would go out unprotected unsaid, or
// when `data` is shorter than m's payload, which holds no field to stamp.
pub fn (mut s E2eStamper) stamp(m candb.Message, mut data []u8) !bool {
	if !m.e2e.declared() {
		return false
	}
	if data.len < m.payload_len() {
		return error('a frame of ${data.len} bytes is shorter than ${m.name} (${m.payload_len()})')
	}
	e := e2e_of_decl(m.e2e)
	why := declared_problem(m, e)
	if why != '' {
		return error('${m.name} declares E2E that cannot be stamped: ${why}; send it as encoded instead')
	}
	k := vkey(m.id, m.ext)
	n := s.sent[k] or { u64(0) }
	e.apply(m, mut data, int(n))
	s.sent[k] = n + 1
	return true
}
