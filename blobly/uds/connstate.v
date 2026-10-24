module uds

// connstate.v — what a tester knows of the session and security state its connection has
// established, and what a gated write needs first: the rules the Diagnostics panel's held
// connection and a script's client both go by. `ConnState.observe` reads them off every exchange a
// Client puts through (Client.state), so a script's write is planned on what its own requests
// established, as the panel's is.

// default_session is DiagnosticSessionControl's defaultSession, which serves no 0x27.
pub const default_session = u8(0x01)

// extended_session is DiagnosticSessionControl's extendedDiagnosticSession.
pub const extended_session = u8(0x03)

// session_name is a DiagnosticSessionControl session by name; 0 is unknown (no 0x10 answered on
// this connection).
pub fn session_name(s u8) string {
	return match s {
		0 { '—' }
		0x01 { 'default' }
		0x02 { 'programming' }
		0x03 { 'extended' }
		0x04 { 'safety' }
		else { '0x${s:02X}' }
	}
}

// unlock_session is the session to switch to before a 0x27 (0 = stay). ISO 14229-1 serves
// SecurityAccess only outside the default session, so the default one — or one nothing has
// answered 0x10 for on this connection (0) — is left for the extended session, the one a
// blobly_emb application unlocks in. Any other known session is kept: a programming session's
// bootloader unlocks in its own.
pub fn unlock_session(session u8) u8 {
	if session == 0 || session == default_session {
		return extended_session
	}
	return 0
}

// seed_sub is the 0x27 requestSeed sub-function of a security level (as an ecu.toml numbers
// levels, 1..8): 2L-1; its sendKey is the next one.
pub fn seed_sub(level u8) u8 {
	return 2 * level - 1
}

// Security is what a connection knows of the ECU's security state: unknown (a fresh connection, or
// after a 0x27 the ECU did not grant — it may have relocked, or not), locked (a session transition
// was answered: ISO 14229-1 relocks on every one), or `level` unlocked (a 0x27 granted it since).
pub struct Security {
pub:
	known bool
	level u8 // known: 0 = locked, else the level unlocked
}

// security_locked is the state a positive 0x10 answer establishes.
pub fn security_locked() Security {
	return Security{
		known: true
	}
}

// security_unlocked is the state a granted 0x27 (or an all-zero seed) establishes.
pub fn security_unlocked(level u8) Security {
	return Security{
		known: true
		level: level
	}
}

// unlocked is the level known to be unlocked, 0 when none is — locked or unknown alike, since
// either way a gated request must unlock first (write_plan's `unlocked`).
pub fn (s Security) unlocked() u8 {
	return if s.known { s.level } else { u8(0) }
}

// words is the state as a tester says it.
pub fn (s Security) words() string {
	if !s.known {
		return 'security unknown'
	}
	return if s.level == 0 { 'locked' } else { 'level ${s.level} unlocked' }
}

// Forget is what a refused request says the connection no longer has.
pub enum Forget {
	nothing
	security // the level relocked (0x33 securityAccessDenied); the session stands
	session  // the session is gone, and the level with it (0x7F serviceNotSupportedInActiveSession)
}

// write_refusal_forgets: what a 0x2E refused with `nrc` says the ECU took back on its own (a reset,
// an S3 or security timeout), so the next write plans that again rather than skipping it on a
// stale belief and being refused the same way. Only what the code names: 0x22 conditionsNotCorrect
// is about the DID's own conditions as often as anything, and forgetting the session on it would
// stop a keep-alive and lose the session it never said was lost.
pub fn write_refusal_forgets(nrc u8) Forget {
	return match nrc {
		0x7F { .session }
		0x33 { .security }
		else { .nothing }
	}
}

// unlock_refusal_forgets: what a 0x27 the ECU ANSWERED without granting says the connection no
// longer has — `nrc` its negative response's code, 0 for an answer that was not one (malformed, or
// with no seed). 0x7F (the service not served in this session): the session is not the one
// believed (an S3 timeout, a reset), so the next unlock switches again. Anything else, 0x7E and a
// malformed answer included: the level is no longer known (a seed request for another level, or a
// key the ECU may have processed, may have changed it).
pub fn unlock_refusal_forgets(nrc u8) Forget {
	return if nrc == 0x7F { Forget.session } else { Forget.security }
}

// ConnState is the session and security state a connection has established, as its own
// exchanges say: session 0 = none known.
pub struct ConnState {
pub mut:
	session  u8
	security Security
}

// forget drops what a refusal says the connection no longer has.
pub fn (mut s ConnState) forget(f Forget) {
	match f {
		.nothing {}
		.security {
			s.security = Security{}
		}
		.session {
			s.session = 0
			s.security = Security{}
		}
	}
}

// words is the state as a tester says it: `extended session, level 1 unlocked`.
pub fn (s ConnState) words() string {
	session := if s.session == 0 {
		'no session known'
	} else {
		'${session_name(s.session)} session'
	}
	return '${session}, ${s.security.words()}'
}

// observe updates the state from one exchange that ended: a positive 0x10 establishes its session,
// locked (ISO 14229-1 relocks on every transition), a positive 0x11 the default session, locked; a
// granted 0x27 key, or an all-zero seed, its level; a 0x27 or 0x2E refusal forgets what its code
// says (unlock_refusal_forgets, write_refusal_forgets). A session change or a 0x27 the ECU may have
// acted on without answering leaves that state unknown; a request that never went out changes
// nothing.
pub fn (mut s ConnState) observe(x Exchange) {
	if x.req.len == 0 || (x.err != '' && !x.timing.sent) {
		return
	}
	sid := x.req[0]
	sub := if x.req.len > 1 { x.req[1] & ~suppress_positive } else { u8(0) }
	answered := x.err == '' // a positive answer, or a suppressed request's quiet success
	match sid {
		sid_diagnostic_session_control {
			if answered {
				// the echo may carry the suppress bit (answer_to accepts it): the session is without it
				s.session = if x.resp.len > 1 { x.resp[1] & ~suppress_positive } else { sub }
				s.security = security_locked()
			} else if !x.negative {
				s.session = 0
				s.security = Security{}
			}
		}
		sid_ecu_reset {
			if sub == 0x04 || sub == 0x05 {
				// enable / disable rapid power shutdown: no reset, nothing changes
			} else if answered && sub >= reset_hard && sub <= reset_soft {
				s.session = default_session
				s.security = security_locked()
			} else if !x.negative {
				// a reset of a kind ISO does not define, or one sent and unanswered: not known
				s.session = 0
				s.security = Security{}
			}
		}
		sid_security_access {
			if answered && sub != 0 {
				if sub & 1 == 0 {
					s.security = security_unlocked(sub / 2)
				} else if x.resp.len > 2 && already_unlocked(x.resp[2..]) {
					s.security = security_unlocked((sub + 1) / 2)
				} else if x.resp.len <= 2 {
					s.forget(.security) // no seed to answer: the level is not known (unlock_refusal_forgets)
				} else if s.security.unlocked() == (sub + 1) / 2 {
					s.forget(.security) // a seed to answer: that level is locked again
				}
			} else if x.negative && x.resp.len == 3 {
				s.forget(unlock_refusal_forgets(x.resp[2]))
			} else if !answered {
				s.forget(.security)
			}
		}
		sid_write_data_by_identifier {
			if x.negative && x.resp.len == 3 {
				s.forget(write_refusal_forgets(x.resp[2]))
			}
		}
		else {}
	}
}

// WritePlan is what a 0x2E needs before it is sent, as the description gates it: a session to
// switch to (0 = stay), a security level to unlock (0 = none; its 0x27 sub-functions are
// seed_sub), or why it cannot be written.
pub struct WritePlan {
pub:
	session u8
	unlock  u8
	refusal string
}

// write_plan: the steps before a write. `declared` is whether the CURRENT description gives the
// DID a write gate at all: none means NOT WRITABLE, never "no requirements" — an empty gate and an
// absent one are the same bytes downstream, so this is asked first and refuses. `session` is the
// connection's (0 = none answered yet), `allowed` the sessions the DID is written in (none = any),
// `level` the level it needs (0 = none), `unlocked` the level this connection has unlocked,
// `can_unlock` whether the tester can compute the node's key (the Diagnostics panel only the
// reference key; a script with a key function of its own, any). The extended session is preferred
// where it is allowed: it is the one a tester writes in. A session change locks the ECU again
// (ISO 14229-1), so a level unlocked before one is unlocked again after it. A level the tester
// cannot unlock is refused, never faked: the write would only be refused with 0x33. A gated write
// is never planned in the default session, which serves no 0x27, and a gate that allows only that
// one is refused as the contradiction it is.
pub fn write_plan(declared bool, session u8, allowed []u8, level u8, unlocked u8, can_unlock bool) WritePlan {
	if !declared {
		return WritePlan{
			refusal: 'not writable: the description declares no write gate for it'
		}
	}
	// a gated write is sent where its level can be unlocked: never the default session, which
	// serves no 0x27 — the unlock would leave it, and the write would go out of its gate
	mut ok := allowed.clone()
	if level != 0 && allowed.len > 0 {
		ok = allowed.filter(it != default_session)
		if ok.len == 0 {
			return WritePlan{
				refusal: 'not writable: its write gate needs security level ${level} but names only the default session, where 0x27 is not served (ISO 14229-1) — the description contradicts itself'
			}
		}
	}
	mut to := u8(0)
	if ok.len > 0 && session !in ok {
		to = if extended_session in ok { extended_session } else { ok[0] }
	} else if ok.len == 0 && level != 0 && unlocked != level {
		// any session: the unlock's own rule, said in the plan rather than done unannounced
		to = unlock_session(session)
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

// steps: what the plan does before the write, each with its requests — the session switch, then
// the unlock.
pub fn (p WritePlan) steps() []string {
	return p.step_words('')
}

// words: the plan's steps, as the Diagnostics panel's write dialog states them before it is
// confirmed (its unlock is always the reference key's).
pub fn (p WritePlan) words() string {
	if p.refusal != '' {
		return p.refusal
	}
	mut steps := p.step_words(' with the reference key')
	steps << 'write (0x2E), then read it back (0x22)'
	return steps.join(', then ')
}

fn (p WritePlan) step_words(key string) []string {
	mut out := []string{}
	if p.session != 0 {
		out << 'switch to the ${session_name(p.session)} session (0x10 ${p.session:02X})'
	}
	if p.unlock != 0 {
		sub := seed_sub(p.unlock)
		out << 'unlock level ${p.unlock}${key} (0x27 ${sub:02X}/${sub + 1:02X})'
	}
	return out
}
