module diaghold

// did.v — the DIDs tab's rules: what a write has to establish first (the session its DID is
// written in, the security level it needs), and what a Read all says in the log.

// parse_did reads a DID typed by hand: one to four hex digits, `0x` optional. none for anything
// else — a typo must not become 0x0000, nor five digits a truncated other DID.
pub fn parse_did(t string) ?u16 {
	mut s := t.trim_space()
	if s.starts_with('0x') || s.starts_with('0X') {
		s = s[2..]
	}
	if s.len == 0 || s.len > 4 {
		return none
	}
	mut v := u16(0)
	for c in s {
		d := match c {
			`0`...`9` { c - `0` }
			`a`...`f` { c - `a` + 10 }
			`A`...`F` { c - `A` + 10 }
			else { return none }
		}
		v = v << 4 | u16(d)
	}
	return v
}

// write_still_current: the last check before a 0x2E goes out, asked by the holder for EVERY
// write, after the session switch and the unlock and immediately before the send: the description
// the write was made under (`req_ident`) must still be the loaded one (`now_ident`). A reload
// while the write was queued, or while an open, a session change or an unlock was slow, may have
// moved its layout or taken its write gate away — the bytes were encoded by the old one. '' = send.
pub fn write_still_current(req_ident string, now_ident string) string {
	if req_ident == now_ident {
		return ''
	}
	return 'not written: the description was reloaded since this write was made — open the dialog again'
}

// WritePlan is what a 0x2E needs before it is sent, as the description gates it: a session to
// switch to (0 = stay), a security level to unlock (0 = none; its 0x27 sub-functions are
// seed_sub), or why the panel cannot write it.
pub struct WritePlan {
pub:
	session u8
	unlock  u8
	refusal string
}

// write_plan: the steps before a write. `declared` is whether the CURRENT description gives the
// DID a write gate at all: none means NOT WRITABLE, never "no requirements" — an empty gate and an
// absent one are the same bytes downstream, so this is asked first and refuses. `session` is the connection's (0 = none answered yet),
// `allowed` the sessions the DID is written in (none = any), `level` the level it needs (0 = none),
// `unlocked` the level this connection has unlocked, `can_unlock` whether the panel can compute
// the node's key (its description names blobly_net's reference key). The extended session is
// preferred where it is allowed: it is the one a tester writes in. A session change locks the ECU
// again (ISO 14229-1), so a level unlocked before one is unlocked again after it. A level the
// panel cannot unlock is refused, never faked: the write would only be refused with 0x33.
pub fn write_plan(declared bool, session u8, allowed []u8, level u8, unlocked u8, can_unlock bool) WritePlan {
	if !declared {
		return WritePlan{
			refusal: 'not writable: the description declares no write gate for it'
		}
	}
	mut to := u8(0)
	if allowed.len > 0 && session !in allowed {
		to = if u8(0x03) in allowed { u8(0x03) } else { allowed[0] }
	}
	have := if to != 0 { u8(0) } else { unlocked }
	if level == 0 || have == level {
		return WritePlan{
			session: to
		}
	}
	if !can_unlock {
		return WritePlan{
			session: to
			refusal: 'needs security level ${level} (0x27 ${seed_sub(level):02X}), and the panel cannot compute this ECU\'s key — only blobly_net\'s reference key ([uds] security_key = "reference"); unlock it from a script'
		}
	}
	return WritePlan{
		session: to
		unlock:  level
	}
}

// seed_sub is the 0x27 requestSeed sub-function of a security level (as an ecu.toml numbers
// levels, 1..8): 2L-1; its sendKey is the next one.
pub fn seed_sub(level u8) u8 {
	return 2 * level - 1
}

// Forget is what a refused 0x2E says the connection no longer has.
pub enum Forget {
	nothing
	security // the level relocked (0x33 securityAccessDenied); the session stands
	session  // the session is gone, and the level with it (0x7F serviceNotSupportedInActiveSession)
}

// write_refusal_forgets: what a 0x2E refused with `nrc` says the ECU took back on its own (a reset,
// an S3 or security timeout), so the next write plans that again rather than skipping it on a
// stale belief and being refused the same way. Only what the code names: 0x22 conditionsNotCorrect
// is about the DID's own conditions as often as anything, and forgetting the session on it would
// stop the keep-alive and lose the session it never said was lost.
pub fn write_refusal_forgets(nrc u8) Forget {
	return match nrc {
		0x7F { .session }
		0x33 { .security }
		else { .nothing }
	}
}

// edit_room is an edit field's buffer size: a DID of `size` bytes as hex (three characters a
// byte) with room to type past it, so too long is said by encode rather than cut by the field —
// and never less than the text it starts with (`text_len`), which it must hold whole.
pub fn edit_room(size int, text_len int) int {
	mut n := if size > 0 { 3 * size + 16 } else { 0 }
	if n < 128 {
		n = 128
	}
	return if text_len + 1 + 16 > n { text_len + 1 + 16 } else { n }
}

// words: the plan's steps, as the write dialog states them before it is confirmed.
pub fn (p WritePlan) words() string {
	if p.refusal != '' {
		return p.refusal
	}
	mut steps := []string{}
	if p.session != 0 {
		steps << 'switch to the ${session_name(p.session)} session (0x10 ${p.session:02X})'
	}
	if p.unlock != 0 {
		sub := seed_sub(p.unlock)
		steps << 'unlock level ${p.unlock} with the reference key (0x27 ${sub:02X}/${sub + 1:02X})'
	}
	steps << 'write (0x2E), then read it back (0x22)'
	return steps.join(', then ')
}

// DidBatch is a Read all: every DID asked in turn. A refusal is that DID's (supported or not, in
// this session or not) and the batch goes on; only the connection failing ends it. Said in the log
// as ONE line — the count, the refusals by code, the summed time — since each DID's own answer and
// time is in the table: thirty lines a press would bury every other.
pub struct DidBatch {
pub mut:
	read    int
	refused int
	nrcs    map[u8]int // refusals by negative response code; 0 = answered but not readable
	failed  string
	t       Timing
}

pub fn (mut b DidBatch) answered(t Timing) {
	b.read++
	b.t = b.t.plus(t)
}

pub fn (mut b DidBatch) refusal(t Timing, nrc u8) {
	b.refused++
	b.nrcs[nrc] = (b.nrcs[nrc] or { 0 }) + 1
	b.t = b.t.plus(t)
}

pub fn (mut b DidBatch) failure(t Timing, why string) {
	b.failed = why
	b.t = b.t.plus(t)
}

pub fn (b DidBatch) going() bool {
	return b.failed == ''
}

// summary is the batch's line (after its timing column): `of` is how many DIDs it was to ask.
pub fn (b DidBatch) summary(of int) string {
	mut line := 'Read all, ${of} DID(s): ${b.read} read'
	if b.refused > 0 {
		mut codes := b.nrcs.keys()
		codes.sort()
		by := codes.map(if it == 0 {
			'unreadable ×${b.nrcs[it]}'
		} else {
			'0x${it:02X} ×${b.nrcs[it]}'
		})
		line += ', ${b.refused} refused (${by.join(', ')})'
	}
	if b.failed != '' {
		rest := of - b.read - b.refused - 1
		line += '; stopped: ${b.failed}'
		if rest > 0 {
			line += ' (${rest} not asked)'
		}
	}
	return line
}

// refused_words is a DID the ECU refused, as its row in the DIDs tab says it: the NRC and `name`,
// its ISO 14229-1 name (uds.nrc_name). The two session refusals say what they mean for a DID —
// served, but not in the session the connection is in — since a session change is exactly what
// the row's Read is kept for.
pub fn refused_words(nrc u8, name string) string {
	if nrc == 0x7F || nrc == 0x7E {
		return '0x${nrc:02X} not supported in this session'
	}
	return '0x${nrc:02X} ${name}'
}
