module diaghold

// unlock.v — the General tab's explicit security access: which level it offers, when its 0x27 may
// go, how a seed is read, and how a refusal is said. Which session it leaves first and what a
// refusal forgets are uds.unlock_session's and uds.unlock_refusal_forgets'; the 0x27 exchange
// itself is the one the DID write path runs (cmd/blobly_net diag_unlock).

// unlock_level_default is the level the selector starts at: the lowest one the description's
// gates name (`levels`, sysview.EcuDesc.security_levels) that the selector offers (1..`max`,
// sysview.max_security_level), else 1.
pub fn unlock_level_default(levels []int, max int) u8 {
	mut best := 0
	for l in levels {
		if l >= 1 && l <= max && (best == 0 || l < best) {
			best = l
		}
	}
	return if best == 0 { u8(1) } else { u8(best) }
}

// unlock_refusal is why an Unlock is not sent ('' = send it). The panel computes only blobly_net's
// reference key, and every wrong key counts toward the ECU's lockout, so a target whose
// description says it will not accept that key is refused before anything goes out: one that names
// another key (no `security_key = "reference"`), or — reached over DoIP (`doip`) — one that does not
// opt into the public key over the network (`allow_bench_key`, which blobly_emb requires on a
// [doip] node: REQ-NET-012). An undescribed target is tried: a simulated ECU, or an ECU nothing here
// describes, may accept it, and a 0x35 then says that it does not.
pub fn unlock_refusal(described bool, ref_key bool, doip bool, bench_key bool) string {
	if !described {
		return ''
	}
	if !ref_key {
		return 'not sent — its description names no reference key ([uds] security_key = "reference"): its key is the OEM\'s, which the panel cannot compute, and a wrong key counts toward its lockout; unlock it from a script with its key function'
	}
	if doip && !bench_key {
		return 'not sent — over DoIP its description does not allow the reference key (no allow_bench_key = true in its doip table): it refuses that key over the network, and a wrong key counts toward its lockout'
	}
	return ''
}

// UnlockStep is the next step before a 0x27, as unlock_step decides it: a refusal (nothing sent), a
// session to switch to first (0 = none), or neither — send the 0x27.
pub struct UnlockStep {
pub:
	refusal string
	session u8
}

// unlock_step is THE gate in front of every 0x27 the panel sends — an Unlock's and a gated DID
// write's alike — asked before the session switch and again right before the 0x27. `policy` is the
// press's own verdict on the reference key (unlock_refusal for its target and description; '' =
// it may be sent), `req_ident` the system that verdict was reached under and `now_ident` the one
// loaded now: the verdict holds only while they are one, since a reload may have taken
// `security_key = "reference"` or `allow_bench_key` away. Then `to`, the session to leave for first
// (uds.unlock_session of the connection's: the default one, or none known, is left — also for a
// write gate that names a level and no session).
pub fn unlock_step(req_ident string, now_ident string, policy string, to u8) UnlockStep {
	if policy != '' {
		return UnlockStep{
			refusal: policy
		}
	}
	stale := unlock_still_current(req_ident, now_ident)
	if stale != '' {
		return UnlockStep{
			refusal: stale
		}
	}
	return UnlockStep{
		session: to
	}
}

// unlock_still_current: the last check before a queued Unlock's 0x27 goes out — the system it was
// decided under (`req_ident`; unlock_refusal read its description) is still the loaded one
// (`now_ident`). A reload while the press waited may have taken the reference key away, and a
// wrong key counts toward the lockout. '' = send.
pub fn unlock_still_current(req_ident string, now_ident string) string {
	if req_ident == now_ident {
		return ''
	}
	return 'no 0x27 sent: the system description was reloaded since this was pressed — press it again'
}

// Seed is what a 0x27 requestSeed answer says.
pub enum Seed {
	locked // a seed to answer with a key
	unlocked // all zero: ISO 14229-1's "already unlocked", and no key is sent
	empty // no seed bytes at all: nothing to compute a key from
}

pub fn seed_state(seed []u8) Seed {
	if seed.len == 0 {
		return .empty
	}
	return if seed.all(it == 0) { Seed.unlocked } else { Seed.locked }
}

// unlock_refusal_words is a 0x27 refused with `nrc` (its ISO 14229-1 name `name`), as the log
// and the strip say it, with what it means for the operator. `key_sent` is whether the refusal
// answers the key (sendKey) rather than the seed request.
pub fn unlock_refusal_words(nrc u8, name string, level u8, key_sent bool) string {
	what := '0x${nrc:02X} ${name}'
	return match nrc {
		0x35 {
			'${what} — this ECU does not accept blobly_net\'s reference key: its algorithm is the OEM\'s, which the panel cannot compute (a script can, with its own key function) — unless another tester asked it for a seed in between'
		}
		0x36 {
			'${what} — too many wrong keys: the ECU is locked out for its delay'
		}
		0x37 {
			'${what} — the ECU\'s lockout delay has not expired; try again later'
		}
		0x24 {
			if key_sent {
				'${what} — the ECU had no seed outstanding for this key'
			} else {
				'${what} — the ECU refused the seed request out of order'
			}
		}
		0x12 {
			'${what} — this ECU has no security level ${level}'
		}
		0x7E, 0x7F {
			'${what} — not served in this session'
		}
		0x22 {
			'${what} — the ECU\'s conditions for unlocking are not met'
		}
		else {
			what
		}
	}
}

// lock_words is the Lock button's tooltip: why returning to the default session is the lock.
pub const lock_words = 'Return to the default session (0x10 01). UDS has no "lock" request: a session transition locks the ECU again, and the default session has no security access at all.'
