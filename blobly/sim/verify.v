// Checking the protection on frames we RECEIVE.
//
// e2e.v protects what the simulation sends. This is the other half: given a frame from the ECU
// under test, does its alive counter advance and does its checksum match? Without it the tool
// can drive a bench but cannot fail one — a unit whose own protection is broken looks exactly
// like a unit whose protection is fine, and the fault ships.
//
// Deliberately stateless per call except for the counter, which cannot be judged from a single
// frame: "did it advance" is a question about the previous one. `Verifier` holds only that.
module sim

import blobly.candb
import blobly.project

// Violation is what is wrong with a received frame, if anything.
pub enum Violation {
	ok
	truncated   // shorter than the DBC message: its protection fields are not all present
	bad_crc     // the checksum does not match the payload
	stalled_ctr // the alive counter repeated
	skipped_ctr // the counter jumped — frames were lost, or the sender restarted
	timeout     // later than its message's E2ETimeout after the last valid frame (check_at)
}

// str is the short form used in the trace, where space is scarce and the reader is scanning.
pub fn (v Violation) str() string {
	return match v {
		.ok { '' }
		.truncated { '!LEN' }
		.bad_crc { '!CRC' }
		.stalled_ctr { '!CNT stalled' }
		.skipped_ctr { '!CNT skipped' }
		.timeout { '!TIMEOUT' }
	}
}

// name is the verdict as a script reads it: Lua's frame.e2e, and what the C ABI's enum bb_e2e
// names (cmd/libblobly e2e.v maps it by variant).
pub fn (v Violation) name() string {
	return match v {
		.ok { 'ok' }
		.truncated { 'truncated' }
		.bad_crc { 'bad_crc' }
		.stalled_ctr { 'repeated' }
		.skipped_ctr { 'skipped' }
		.timeout { 'timeout' }
	}
}

// severity orders verdicts for the worst of several: a frame that cannot be judged, then a CRC
// that fails, a frame late, a counter that jumped, one that repeated.
fn severity(v Violation) int {
	return match v {
		.ok { 0 }
		.stalled_ctr { 1 }
		.skipped_ctr { 2 }
		.timeout { 3 }
		.bad_crc { 4 }
		.truncated { 5 }
	}
}

// worst is the worse of two verdicts — what a frame protected in several windows reads as.
pub fn worst(a Violation, b Violation) Violation {
	return if severity(b) > severity(a) { b } else { a }
}

// Verifier checks one message's protection across successive frames, window by window (#615).
pub struct Verifier {
pub:
	msg     candb.Message
	windows []E2e
pub mut:
	state []WindowState // per window, sized at the first check
	// each window's verdict on the last frame checked, in the order of `windows`
	last []Violation
	seen u64 // frames checked
	bad  u64 // frames that failed in any window
}

// WindowState is what one window's check carries from frame to frame.
pub struct WindowState {
pub mut:
	// u64 with an explicit "nothing yet" flag rather than a signed sentinel: a counter may be
	// wide, and narrowing it into an int made a high-bit value look negative — which read as
	// "first frame" and skipped the check on every frame after it.
	last_ctr u64
	have_ctr bool
	// when the last valid frame came (check_at): its raw stamp, in the clock domain `valid_clock`
	last_valid_ns i64
	valid_clock   string
	have_valid    bool
}

// new_verifier is a verifier of message `msg` protected in `windows`.
pub fn new_verifier(msg candb.Message, windows []E2e) Verifier {
	return Verifier{
		msg:     msg
		windows: windows.clone()
		state:   []WindowState{len: windows.len}
	}
}

// holds is whether `data` holds the protection field `name` whole (and its multiplexor), if the
// message has one.
fn (v &Verifier) holds(name string, data []u8) bool {
	sig := v.msg.signal_named(name) or { return true }
	return v.msg.holds(sig, data.len)
}

// check judges one received payload in every window, the frame's verdict the worst of theirs.
pub fn (mut v Verifier) check(data []u8) Violation {
	return v.judge_frame(data, '', 0, false)
}

// check_at judges a received payload as check does, and its receive stamp `t_ns` in the clock
// domain `clock` (CanFrame.hw_ns / hw_domain: raw stamps of one domain are exactly comparable)
// against each window's E2ETimeout, its receiver's sender-loss timeout (0 or absent for none): a
// frame whose CRC passes more than that after the last valid frame — its CRC right, its counter
// not a repeat — is `.timeout`, ahead of its counter's verdict, and the counter is judged against
// it from there. `clock` '' is a frame with no stamp, whose time is only when it was read: valid,
// it ends the baseline rather than moving it, and a frame of another domain starts a new one, so
// no gap is measured across a time that is not the bus's.
pub fn (mut v Verifier) check_at(data []u8, clock string, t_ns i64) Violation {
	return v.judge_frame(data, clock, t_ns, true)
}

fn (mut v Verifier) judge_frame(data []u8, clock string, t_ns i64, timed bool) Violation {
	if v.state.len != v.windows.len {
		v.state = []WindowState{len: v.windows.len}
	}
	v.seen++
	mut verdicts := []Violation{cap: v.windows.len}
	mut out := Violation.ok
	for i in 0 .. v.windows.len {
		mut got := v.check_window(i, data)
		if timed {
			got = v.timed(i, got, clock, t_ns)
		}
		verdicts << got
		out = worst(out, got)
	}
	v.last = verdicts
	if out != .ok {
		v.bad++
	}
	return out
}

// check_window judges window i of one received payload.
//
// Order matters here as much as it does when stamping: the checksum is verified against the
// frame EXACTLY as received, before anything is inferred from the counter, because a frame
// whose checksum is wrong tells us nothing reliable about its counter — those bits are just as
// likely to be corrupt.
fn (mut v Verifier) check_window(i int, data []u8) Violation {
	e := v.windows[i]
	// A short frame cannot be judged: the missing checksum and counter bits read as zero, and
	// an EMPTY payload computes zero for every supported checksum — which then matches the
	// absent checksum field and sails through the first-counter rule as clean. A malformed
	// frame must not be able to look better than a well-formed one.
	if data.len < v.msg.dlc || !v.holds(e.crc, data) || !v.holds(e.counter, data) {
		return .truncated
	}
	if e.crc != '' {
		for sig in v.msg.active_signals(data) {
			if sig.name != e.crc {
				continue
			}
			// Compare the WHOLE field at its declared width. Narrowing to u8 threw away the
			// upper bits of a wider checksum — a frame whose low byte happened to match read
			// as clean — while a narrower field is truncated by the sender when stamped, so
			// comparing against the full 8-bit value labelled the sender's own frames !CRC.
			w := mask_of_bits(sig.length)
			got := sig.raw_value(data) & w
			if got != u64(e.checksum(v.msg, sig, data)) & w {
				return .bad_crc
			}
			break
		}
	}
	if e.counter == '' {
		return .ok
	}
	for sig in v.msg.active_signals(data) {
		if sig.name != e.counter {
			continue
		}
		cur := sig.raw_value(data)
		// The modulus is the signal's own width, at any width (forcing it to zero past 30 bits
		// turned a legal 31-bit wrap into a reported skip) — or Profile 1's 0..14, whose 15 is
		// never a valid value and so reads as a skip from wherever it appears.
		span := e.counter_span(sig)
		prev := v.state[i].last_ctr
		had := v.state[i].have_ctr
		v.state[i].last_ctr = cur
		v.state[i].have_ctr = true
		if span > 0 && cur >= span {
			// a value the counter can never hold (Profile 1's 15): wrong from any frame, the
			// first included, and it predicts nothing about the next
			v.state[i].have_ctr = false
			return .skipped_ctr
		}
		if !had {
			return .ok // first frame: there is nothing to compare against
		}
		expect := if span > 0 { (prev + 1) % span } else { prev + 1 }
		if cur == prev {
			return .stalled_ctr
		}
		if cur != expect {
			// A jump is not automatically the sender's fault — frames can be lost on a real
			// bus — but it is exactly what a receiver would reject, so it is reported and the
			// operator decides. Reporting only stalls would miss a sender that skips.
			return .skipped_ctr
		}
		break
	}
	return .ok
}

// timed is window i's verdict `got` with its time judged against the window's E2ETimeout.
fn (mut v Verifier) timed(i int, got Violation, clock string, t_ns i64) Violation {
	limit_ms := i64(declared_timeout_ms(v.msg, v.windows[i]))
	if limit_ms == 0 || got in [.truncated, .bad_crc] {
		return got
	}
	st := v.state[i]
	late := clock != '' && st.have_valid && st.valid_clock == clock
		&& t_ns - st.last_valid_ns > limit_ms * 1_000_000
	// new data: neither a repeat nor a value the counter never holds (check forgets the counter
	// for one of those, where a jump keeps it)
	if got != .stalled_ctr && !(got == .skipped_ctr && !st.have_ctr) {
		v.state[i].have_valid = clock != ''
		v.state[i].valid_clock = clock
		v.state[i].last_valid_ns = t_ns
	}
	return if late { Violation.timeout } else { got }
}

// declared_timeout_ms is the E2ETimeout a message's file declares for window `e` — the
// declaration of a window over the same bytes (BO_ scope being the whole payload); 0 for none.
pub fn declared_timeout_ms(m candb.Message, e E2e) u32 {
	a0, a1 := e.bytes(m)
	for d in m.e2e {
		if !d.has_timeout {
			continue
		}
		w := m.e2e_window(d) or { continue }
		b0, b1 := E2e{
			offset: w.offset
			length: w.length
		}.bytes(m)
		if a0 == b0 && a1 == b1 {
			return d.timeout_ms
		}
	}
	return 0
}

// labelled is each window's verdict on the last frame checked, by its name (E2e.label).
pub fn (v &Verifier) labelled() []WindowVerdict {
	mut out := []WindowVerdict{cap: v.last.len}
	for i, got in v.last {
		if i < v.windows.len {
			out << WindowVerdict{v.windows[i].label(v.msg), got}
		}
	}
	return out
}

// WindowVerdict is one window's verdict on a frame.
pub struct WindowVerdict {
pub:
	name    string
	verdict Violation
}

fn mask_of_bits(bits int) u64 {
	return if bits >= 64 { ~u64(0) } else { (u64(1) << bits) - 1 }
}

// VerifySet is the verifiers for one channel.
//
// Keyed by id AND frame format, which is what identifies a CAN message — the database merge
// already treats them as distinct. Keyed on the number alone, a standard and an extended
// message sharing a raw id overwrote each other and one verifier judged both formats, merging
// two independent counter streams into a stream of reported skips.
pub struct VerifySet {
pub mut:
	by_key map[string]Verifier
	// WHICH KEYS CAME FROM `verify:` rather than from a node's `protect:`, and under what NAME
	// that entry described them (#95). The two sources are mixed into one set on purpose — a
	// project describes each protected message once and both directions follow it — but they
	// mean opposite things about who SENDS the message, and the self-sent notice depends on
	// that: a `protect:` message is ours BY CONSTRUCTION, so warning that we transmit it would
	// fire on every correct project that simulates a protected node. `verify:` describes the ECU
	// under test, so a frame of ours carrying one is the mistake. replay.v already made this
	// distinction by hand (`verifiers_for(live, [], sc.verify)` — "verify: ONLY, never our
	// own"); recorded here, nothing has to make it by hand again.
	//
	// THE NAME IS KEPT HERE AND NOT READ BACK OFF THE Verifier, because the Verifier that
	// survives a merge collision may be the `protect:` one: two channel entries on a wire can
	// describe one CAN id from two databases that name it differently, and with equal E2E
	// settings merge_into keeps the first. The notice would then have named a message `verify:`
	// does not list (codex on #289).
	from_verify map[string]VerifyOrigin
}

// VerifyOrigin is the message a `verify:` entry actually resolved to — not a re-lookup of it.
//
// IT CARRIES THE DECLARATION because inferring one later cannot be made right. build_coverage
// used to re-match the key across every database on the wire and take a J1939 declaration from
// whichever message it found; but two databases can define the same (id, ext), the merge keeps
// the FIRST, and so an undeclared verified message could inherit PGN matching from a duplicate
// definition that was discarded — reinstating exactly the false self-send warning the
// declaration guard exists to prevent (codex on #289).
//
// The id and format ride along for the same reason: the PGN a key belongs to is a property of
// the message that satisfied the entry, and deriving it by parsing the key back would be the
// same re-inference in another spelling.
pub struct VerifyOrigin {
pub:
	name  string
	id    u32
	ext   bool
	j1939 bool // that message's own `BA_ "VFrameFormat" ... J1939PG`
}

// Coverage is `verify:`'s answer for one wire, INDEXED — built once when a run starts and then
// only read. It replaces a predicate that walked every message of every database on the wire,
// which was fine until it moved onto the transmit path: with the notice asked at each successful
// send, a saturated replay against a large automotive database made that O(frames x messages),
// under the global app mutex, for traffic that had nothing to do with the verified message
// (codex on #289).
//
// Three tables, because the question has three answers and each must be O(1):
//   names   - the keys `verify:` describes, and the name each entry gave them
//   defined - every message the wire's databases define, so a DEFINED id can never be mistaken
//             for another one sharing its PGN
//   pgns    - PGN -> the `verify:` key it belongs to, which is what recognises a live J1939
//             frame whose priority and source address the DBC does not carry
pub struct Coverage {
pub mut:
	names   map[string]string
	defined map[string]bool
	pgns    map[u32]string
}

// build_coverage indexes one wire's `verify:` entries against the databases it will be read with.
// `from_verify` comes from the merged VerifySet, so it already carries the provenance split — a
// node's `protect:` message is ours by construction and is not in it.
pub fn build_coverage(dbs []candb.Database, from_verify map[string]VerifyOrigin) Coverage {
	mut c := Coverage{}
	for k, origin in from_verify {
		c.names[k] = origin.name
	}
	for db in dbs {
		for m in db.messages {
			c.defined[vkey(m.id, m.ext)] = true
		}
	}
	// A PGN ENTRY NEEDS THE FILE TO HAVE SAID SO. An extended id alone is not evidence:
	// j1939_pgn computes a PGN for any 29-bit value, so a UDS request and its response
	// (0x18DA10F1 / 0x18DAF110) share one — and this notice makes a definite CLAIM about the
	// operator's configuration. Matching a `verify:` entry against an id defined NOWHERE, on
	// nothing but a shared bit pattern, is how a UDS response this app hosts gets reported as
	// the request the project asked to verify (codex on #289). `Message.j1939` is
	// `BA_ "VFrameFormat" … J1939PG`: the file saying so, which is the only evidence there is.
	//
	// The cost of requiring it is that a J1939 database with no such attribute — most of them —
	// gets exact-key matching only, so a `verify:` entry replayed at another source address goes
	// unreported. A missing advisory, never a wrong one.
	// FROM THE ORIGIN, not from the databases. Re-matching the key across every database let an
	// undeclared verified message inherit a declaration from a DUPLICATE definition the merge had
	// already discarded — two databases on a wire can define the same (id, ext), the first wins
	// for verification, and the declaration must come from that same one (codex on #289).
	mut owner := map[u32]string{}
	mut ambiguous := map[u32]bool{}
	for k, origin in from_verify {
		if !origin.ext || !origin.j1939 {
			continue
		}
		p := candb.j1939_pgn(origin.id)
		if prev := owner[p] {
			if prev != k {
				// TWO VERIFIED MESSAGES ON ONE PGN — source-specific definitions of a parameter
				// group, or PDU1 messages differing by destination. A single-valued table kept
				// whichever was visited last, so a frame at some third address was reported and
				// LATCHED under a name that may not be the one it belongs to. Neither candidate
				// is more right than the other, and this notice's contract is that it names the
				// message `verify:` listed — so where it cannot, it says nothing.
				ambiguous[p] = true
			}
			continue
		}
		owner[p] = k
	}
	for p, k in owner {
		if p in ambiguous {
			continue
		}
		c.pgns[p] = k
	}
	return c
}

// covers answers whether a live frame id is one `verify:` describes, returning the KEY of the
// entry it matched — the message's, never the wire's, so a caller latching a once-per-message
// notice on it says one line however many source addresses a J1939 message arrives under.
//
// The order is the rule. An exact match wins outright; then a DEFINED message is that message,
// whatever shares its PGN — j1939_pgn applies to any 29-bit id with nothing testing that the bus
// is J1939 at all, and a UDS request and its response share one, so without this step
// transmitting the response would read as the request the project asked to verify. What is left
// is an id defined nowhere that shares a PGN with one that is, which on a J1939 bus IS the same
// parameter group from another source address — the case this exists for.
pub fn (c Coverage) covers(id u32, ext bool) ?string {
	k := vkey(id, ext)
	if k in c.names {
		return k
	}
	if k in c.defined {
		return none // a different message, which happens to share a PGN
	}
	if ext {
		if key := c.pgns[candb.j1939_pgn(id)] {
			return key
		}
	}
	return none
}

// name_of is the name the `verify:` entry gave a key — '' for one it does not describe.
pub fn (c Coverage) name_of(key string) string {
	return c.names[key] or { '' }
}

// self_sent_warning is what that notice says. Here rather than in the GUI so the wording is
// pinned by a test, and so the headless runner would say the same thing.
//
// SAID ONCE PER MESSAGE PER RUN, and the latch for that is the caller's, not this set's: a
// VerifySet is built per rx_loop, so a reader handoff or a mid-run channel toggle would rebuild
// it and repeat the notice — the same reason the teardown carries health, cadence, diagnostics
// and load to the successor rather than letting them restart.
//
// IT REPORTS A FRAME, NOT A PROPERTY OF THE PROJECT, and the distinction is the whole wording.
// What was observed is one transmission; what caused it might be a simulated node, a generator,
// a replay — or a single Quick Send, a trace resend, or one `can.send` from a script, none of
// which say anything about how the project is configured. An earlier draft asserted "is a
// message this project transmits itself", which for a one-off manual send is a claim about the
// configuration that the frame does not support, latched for the run and unretractable.
//
// Nor does it claim the entry checks nothing: from one frame that cannot be known, since a
// message with a real sender beside ours is still genuinely checked for the other sender's
// frames. It states what happened and what follows from it, and leaves the judgement to the
// operator — who is the one who can tell whether it was meant. Same rule as stale.v, which
// reports that traffic stopped and refuses to say whether that is a fault.
pub fn self_sent_warning(name string, id u32, ext bool) string {
	// THE MESSAGE, and the wire id beside it. Naming only the id was useless in the case this
	// feature exists for: a J1939 frame replayed at source address 0x21 reports 0x0CF00421 for a
	// `verify: EEC1` written against 0x0CF00400, so the operator is given a number that appears
	// nowhere in their project and never the name that does.
	return 'verify: a frame this app sent carried ${name} (0x${id:X}${if ext {
		' ext'
	} else {
		''
	}}), which `verify:` lists — our own frames are never verified, so that entry checks only frames somebody else sends'
}

// resolve returns the verifier key for a received frame, adopting a J1939 PGN match when the
// exact id is unknown — a live frame carries a different priority and source address than the
// DBC records, so an exact key never matches it.
//
// Lives here rather than in the GUI because it decides how received wire frames are
// INTERPRETED, and a frontend-local copy would give every other consumer different semantics.
// Counter state is kept per ACTUAL id: two source addresses are two senders with two
// independent sequences.
pub fn (mut s VerifySet) resolve(dbs []candb.Database, id u32, ext bool) ?string {
	k := vkey(id, ext)
	if k in s.by_key {
		return k
	}
	for db in dbs {
		m := db.lookup_frame(id, ext) or { continue }
		src := vkey(m.id, m.ext)
		if src !in s.by_key {
			continue
		}
		proto := s.by_key[src] or { continue }
		s.by_key[k] = new_verifier(proto.msg, proto.windows)
		// DELIBERATELY NOT marking the adopted key as verify:-sourced (#95). It was, briefly,
		// to reach the J1939 case — but verify_covers' own PGN walk already resolves a live
		// source address to the message key from these same databases, so it bought nothing,
		// and it made the answer depend on whether a FOREIGN frame had adopted that address
		// first: with the mark, our frame at the adopted id took verify_covers' exact-key fast
		// path and came back keyed on the WIRE id, while our frame at any other address came
		// back keyed on the MESSAGE — one `verify:` entry latching under two keys and saying
		// its once-per-message line twice.
		return k
	}
	return none
}

// vkey identifies a message the way the rest of the codebase does.
pub fn vkey(id u32, ext bool) string {
	return '${id}|${ext}'
}

// verifiers_for builds the set a channel should check, from the same `protect:` configuration
// that decides what the simulation stamps.
//
// Reusing that configuration is the point: a project describes each protected message once, and
// both directions follow it. Having to declare "check this on receive" separately would let the
// two drift, and the drift would look like a bug in the ECU.
pub fn verifiers_for(db candb.Database, nodes []project.NodeCfg, verify []project.ProtectCfg) VerifySet {
	mut out := VerifySet{}
	// Channel-level `verify:` FIRST, because it describes the ECU under test — the one node a
	// rest-bus setup deliberately does not simulate, and therefore the one whose protection no
	// simulated node's `protect:` can ever describe. Its messages are found anywhere in the
	// database, since we are not the sender.
	// the entries by the message each resolves to, in order: one window each (windows_of)
	mut order := []string{}
	mut msg_of := map[string]candb.Message{}
	mut entries_of := map[string][]project.ProtectCfg{}
	for p in verify {
		for m in db.messages {
			if m.name != p.message {
				continue
			}
			if want := p.id {
				if m.id != want {
					continue // an explicit id disambiguates a name carried by several messages
				}
			}
			if want := p.extended {
				if m.ext != want {
					continue // one id can exist in BOTH formats; the selector must say which
				}
			}
			if !verify_usable(m, p) {
				break // reported by validate_verify; building it anyway checks the wrong thing
			}
			k := vkey(m.id, m.ext)
			if k !in msg_of {
				order << k
				msg_of[k] = m
			}
			entries_of[k] << p
			break
		}
	}
	for k in order {
		m := msg_of[k] or { continue }
		ws := windows_of(m, entries_of[k] or { [] })
		if ws.len == 0 {
			continue
		}
		out.by_key[k] = new_verifier(m, ws)
		// this one describes the ECU under test, not us — and it is THIS message, whose
		// declaration travels with it rather than being looked up again later
		out.from_verify[k] = VerifyOrigin{
			name:  m.name
			id:    m.id
			ext:   m.ext
			j1939: m.j1939
		}
	}
	for n in nodes {
		// messages_from, not db.messages: the STAMPING path scopes to the sender, so a merged
		// database with the same message name on two transmitters could otherwise verify against
		// a different id, layout and field positions than were sent. What it stamps, window for
		// window (protection_for's entries; an entry not stamped is not checked either).
		for m in db.messages_from(n.name) {
			mine := n.protect.filter(it.message == m.name)
			if mine.len == 0 {
				continue
			}
			k := vkey(m.id, m.ext)
			if k in out.by_key {
				continue
			}
			ws := windows_of(m, mine.filter(!it.window_malformed && shape_problem(m, e2e_of(it)) == none))
			if ws.len > 0 {
				out.by_key[k] = new_verifier(m, ws)
			}
		}
	}
	return out
}

// verify_usable is the single definition of "this entry will actually check something".
//
// The builder and the validator both consult it, because they disagreed: validation reported a
// malformed id as "ignored" while verifiers_for went ahead and built a verifier for the
// repaired value — so the measurement logged a warning and then checked the wrong frame, which
// is worse than either alone. One predicate, no drift.
pub fn verify_usable(m candb.Message, p project.ProtectCfg) bool {
	if p.id_malformed || p.data_id_malformed || p.extended_malformed || p.window_malformed {
		return false
	}
	if p.counter == '' && p.crc == '' {
		return false
	}
	if p.counter != '' && p.counter == p.crc {
		return false // one field cannot be both; see validate_verify for why
	}
	if p.crc != '' && p.profile !in candb.e2e_profiles {
		return false
	}
	if _ := shape_problem(m, e2e_of(p)) {
		return false
	}
	mut have := map[string]candb.Signal{}
	for sg in m.signals {
		have[sg.name] = sg
	}
	for name in [p.counter, p.crc] {
		if name == '' {
			continue
		}
		sg := have[name] or { return false }
		if sg.is_multiplexed {
			return false // present only on some frames; the rest would go unchecked
		}
	}
	return true
}

// merge_into folds another config's verifiers in, reporting any that collide.
//
// Two channel entries may share one physical bus, and each validates on its own — so one naming
// a counter and another naming the CRC for the same frame both passed, and a plain
// insert-if-absent silently kept the first and dropped the second check. Belongs here rather
// than in a frontend loop: it decides which checks actually run on the wire.
pub fn (mut s VerifySet) merge_into(other VerifySet) []string {
	mut warns := []string{}
	for k, v in other.by_key {
		// PROVENANCE FIRST, before either `continue` below. A key can arrive from a node's
		// `protect:` on one channel entry and from `verify:` on another sharing the wire, and
		// carrying it only on the insert path made the answer depend on the order of app.sims —
		// the same message reported as self-sent or not according to which entry was listed
		// first. verifiers_for resolves that collision deterministically in favour of `verify:`
		// (it builds those keys first); this keeps the merge agreeing with it.
		if origin := other.from_verify[k] {
			// FIRST WINS, matching by_key below. Overwriting made the notice name the SECOND
			// entry's message while the FIRST entry's verifier is what runs — order-dependent in
			// exactly the way carrying provenance through the merge was meant to end.
			if k !in s.from_verify {
				s.from_verify[k] = origin
			}
		}
		if existing := s.by_key[k] {
			// data_id too: it is mixed into the checksum, so two entries agreeing on every
			// other field but differing here produce DIFFERENT expected checksums. Treating
			// them as identical retained the first and reported the other's traffic as !CRC
			// with no conflict warning — the precise outcome merge_into exists to prevent.
			if same_windows(existing.windows, v.windows) {
				continue // the same entry twice: harmless
			}
			warns << 'verify: "${v.msg.name}" is configured differently on two channel entries sharing this bus — only the first applies'
			continue
		}
		s.by_key[k] = v
	}
	return warns
}

// validate_verify reports channel-level `verify:` entries that will check nothing.
//
// Node-level `protect:` goes through validate_protection; these did not, so a misspelled
// message or signal silently produced no verifier at all and every frame came back clean —
// disabling the bench check the user believes is running. A check that quietly does nothing is
// worse than no check, because it is trusted.
pub fn validate_verify(db candb.Database, verify []project.ProtectCfg) []string {
	mut warns := []string{}
	mut claimed := map[string]project.ProtectCfg{}
	mut msg_by := map[string]candb.Message{}
	mut windowed := map[string][]project.ProtectCfg{}
	for p in verify {
		if p.id_malformed {
			// a stripped character produces a different VALID id, so the entry binds to
			// whatever lives there and no range check can see the mistake
			warns << 'verify: the id on "${p.message}" is not a valid number — entry ignored'
			continue
		}
		if p.crc != '' && p.profile !in candb.e2e_profiles {
			// checksum_of falls back to sum8, so real traffic using the intended algorithm is
			// reported corrupt while the configuration looks fine
			warns << 'verify: unknown profile "${p.profile}" on ${p.message} — traffic would be reported corrupt'
		}
		mut matches := []candb.Message{}
		for m in db.messages {
			if m.name != p.message {
				continue
			}
			if want := p.id {
				if m.id != want {
					continue
				}
			}
			if want := p.extended {
				if m.ext != want {
					continue
				}
			}
			matches << m
		}
		if matches.len == 0 {
			warns << 'verify: no message "${p.message}" in the database — nothing is checked'
			continue
		}
		if matches.len > 1 {
			ids := matches.map('0x${it.id:X}${if it.ext { ' ext' } else { '' }}').join(', ')
			warns << 'verify: "${p.message}" matches several messages (${ids}) — add an id:/extended: to say which'
			continue
		}
		m := matches[0]
		// Two entries resolving to ONE message are two windows, each naming its own: one naming
		// none beside another, or overlapping one before it, is left out (windows_of).
		k := '${m.id}|${m.ext}'
		if prev := claimed[k] {
			if !p.window() || !prev.window() {
				warns << 'verify: "${p.message}" and "${prev.message}" both describe 0x${m.id:X} and do not each name a window (offset:/length:) — only the first applies; give each its window, or put counter and crc in ONE entry'
			}
		} else {
			claimed[k] = p
		}
		if verify_usable(m, p) && p.window() {
			if k !in msg_by {
				msg_by[k] = m
			}
			windowed[k] << p
		}
		mut have := map[string]bool{}
		for sg in m.signals {
			have[sg.name] = true
		}
		if p.extended_malformed {
			warns << 'verify: the extended: selector on "${p.message}" is not true/false — entry ignored'
		}
		if p.data_id_malformed {
			warns << 'verify: the data_id on "${p.message}" is not a valid number — entry ignored'
		}
		if p.window_malformed {
			warns << 'verify: the window of "${p.message}" is not two whole numbers, offset: and length: (> 0) — entry ignored'
		}
		if p.counter != '' && p.counter == p.crc {
			// check() validates that field as a checksum and then reads the SAME bits as an
			// alive counter, so ordinary frames are reported stalled or skipped whenever their
			// checksum does not happen to increment by one
			warns << 'verify: counter and crc are both "${p.counter}" on ${p.message} — one field cannot be both'
		}
		for sg in m.signals {
			if sg.is_multiplexed && (sg.name == p.counter || sg.name == p.crc) {
				// active_signals excludes it on every frame selecting another branch, so those
				// frames return a clean verdict without the configured check ever running
				warns << 'verify: "${sg.name}" on ${p.message} is multiplexed — frames selecting another branch would go unchecked'
			}
		}
		if p.counter != '' && p.counter !in have {
			warns << 'verify: counter "${p.counter}" is not a signal of ${p.message}'
		}
		if p.crc != '' && p.crc !in have {
			warns << 'verify: checksum "${p.crc}" is not a signal of ${p.message}'
		}
		if p.counter == '' && p.crc == '' {
			warns << 'verify: "${p.message}" names neither counter nor crc — nothing is checked'
		}
		if why := shape_problem(m, e2e_of(p)) {
			warns << 'verify: ${p.message}: ${why} — entry ignored'
		}
	}
	for k, entries in windowed {
		m := msg_by[k] or { continue }
		mut kept := []E2e{}
		for p in entries {
			mut e := e2e_of(p)
			e.group = window_name(m, e)
			if why := clash_with(kept, m, e) {
				warns << 'verify: ${p.message}: the window at byte ${e.offset}: ${why} — entry ignored'
				continue
			}
			kept << e
		}
	}
	return warns
}

// same_windows: two protections check alike, window for window.
fn same_windows(a []E2e, b []E2e) bool {
	if a.len != b.len {
		return false
	}
	for i, x in a {
		y := b[i]
		if x.counter != y.counter || x.crc != y.crc || x.profile != y.profile
			|| !same_data_id(x.data_id, y.data_id) || x.data_id_mode != y.data_id_mode
			|| x.offset != y.offset || x.length != y.length {
			return false
		}
	}
	return true
}
