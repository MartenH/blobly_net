module diaghold

// unlock.v — the General tab's explicit security access: which level it offers, which session it
// switches to first, how a seed is read, and how a refusal is said. The 0x27 exchange itself is
// the one the DID write path runs (cmd/blobly_net diag_unlock).

// extended_session is DiagnosticSessionControl's extendedDiagnosticSession.
pub const extended_session = u8(0x03)

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

// unlock_refusal is why an Unlock is not sent ('' = send it). The panel computes only blobly_net's
// reference key, and every wrong key counts toward the ECU's lockout, so a target whose
// description says its key is another (`described`, and no `security_key = "reference"`) is
// refused before anything goes out. An undescribed target is tried: a simulated ECU, or an ECU
// nothing here describes, may accept it, and a 0x35 then says that it does not.
pub fn unlock_refusal(described bool, ref_key bool) string {
	if described && !ref_key {
		return 'not sent — its description names no reference key ([uds] security_key = "reference"): its key is the OEM\'s, which the panel cannot compute, and a wrong key counts toward its lockout; unlock it from a script with its key function'
	}
	return ''
}

// unlock_still_current: the last check before a queued Unlock's 0x27 goes out — the system it was
// decided under (`req_ident`; unlock_refusal read its description) is still the loaded one
// (`now_ident`). A reload while the press waited may have taken the reference key away, and a
// wrong key counts toward the lockout. '' = send.
pub fn unlock_still_current(req_ident string, now_ident string) string {
	if req_ident == now_ident {
		return ''
	}
	return 'not sent: the system description was reloaded since Unlock was pressed — press it again'
}

// unlock_refusal_forgets: what a refused 0x27 says the connection no longer has. 0x7F (the service
// not served in this session): the session is not the one the panel believed (an S3 timeout, a
// reset), so the next Unlock switches again. Anything else, 0x7E included — a sub-function served
// in another session says nothing about which one this is: the level is no longer known (a seed
// request for another level, or a wrong key, may have relocked the ECU), so the next write
// unlocks again.
pub fn unlock_refusal_forgets(nrc u8) Forget {
	return if nrc == 0x7F { Forget.session } else { Forget.security }
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
