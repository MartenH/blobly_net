module diaghold

// unlock.v — the General tab's explicit security access: which level it offers, which session it
// switches to first, how a seed is read, and how a refusal is said. The 0x27 exchange itself is
// the one the DID write path runs (cmd/blobly_net diag_unlock).

// max_level is the highest security level a tester can pick (blobly_emb's ecu.toml numbers them
// 1..8; sysview.max_security_level, restated: this package has no dependencies).
pub const max_level = 8

// extended_session is DiagnosticSessionControl's extendedDiagnosticSession.
pub const extended_session = u8(0x03)

// unlock_level_default is the level the selector starts at: the lowest one the description's
// gates name (`levels`, sysview.EcuDesc.security_levels), else 1.
pub fn unlock_level_default(levels []int) u8 {
	mut best := 0
	for l in levels {
		if l >= 1 && l <= max_level && (best == 0 || l < best) {
			best = l
		}
	}
	return if best == 0 { u8(1) } else { u8(best) }
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
			'${what} — this ECU does not accept blobly_net\'s reference key; its algorithm is the OEM\'s, which the panel cannot compute (a script can, with its own key function)'
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
