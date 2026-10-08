module main

import uds
import vgui
import diaghold
import sysview

// ---- Security access (0x27) on the held connection ----
//
// ONE seed/key exchange, with blobly_net's reference key (uds.security_key: seed XOR 0xFF), run by
// both the General tab's Unlock and a DID write whose gate needs a level (diaghold.write_plan). The
// panel computes no other key: an ECU that answers the reference key with 0x35 is said to be the
// OEM's (diaghold.unlock_refusal_words). Lock is a return to the default session, the only way
// UDS takes a level back.

// UnlockUi is the General tab's security control. GUI thread only.
struct UnlockUi {
mut:
	key   string // the target the level was chosen for: another target starts at its own default
	ident string // ... and the description it was derived from: a reload starts at the new default
	level int    // 1..sysview.max_security_level
}

// diag_unlock runs 0x27 for `level` on the held connection, in the session it is in, and records
// the level on the connection and the strip. The returned line is the outcome, which annotates the
// last exchange's entry (the seed and the key are in the entries themselves). The second value:
// an error was the ECU answering, which keeps the connection.
fn (mut app App) diag_unlock(gen u64, mut h HeldConn, level u8) (DiagOut, bool) {
	sub := diaghold.seed_sub(level)
	seed := h.cli.security_request_seed(sub) or {
		return app.unlock_failed(gen, mut h, '0x27 ${sub:02X} (request seed)', level, false,
			err, answered(err))
	}
	mut line := ''
	match diaghold.seed_state(seed) {
		.empty {
			return app.unlock_failed(gen, mut h, '0x27 ${sub:02X} (request seed)', level, false,
				error('the answer carries no seed'), true)
		}
		.unlocked {
			line = 'level ${level} already unlocked (an all-zero seed; no key sent)'
		}
		.locked {
			h.cli.security_send_key(sub + 1, uds.security_key(seed)) or {
				return app.unlock_failed(gen, mut h, '0x27 ${sub + 1:02X} (reference key)', level, true,
					err, answered(err))
			}
			line = 'level ${level} unlocked (reference key)'
		}
	}
	h.security = level
	mut st := app.diag_status_copy()
	st.security = level
	st.unlock_why = ''
	app.diag_set_status(gen, st)
	return DiagOut{
		line: line
	}, false
}

// unlock_failed is a refused or failed 0x27 step: said by its NRC's meaning, and on the strip; what
// the refusal may have taken back is forgotten (diaghold.unlock_refusal_forgets). `ecu_answered` is
// returned as the second value: the ECU answered, so the connection is kept.
fn (mut app App) unlock_failed(gen u64, mut h HeldConn, step string, level u8, key_sent bool, err IError, ecu_answered bool) (DiagOut, bool) {
	mut words := err.msg()
	if err is uds.NegativeResponse {
		words = diaghold.unlock_refusal_words(err.nrc, uds.nrc_name(err.nrc), level, key_sent)
		app.diag_forget(gen, mut h, diaghold.unlock_refusal_forgets(err.nrc) == .session)
	}
	mut st := app.diag_status_copy()
	st.unlock_why = 'level ${level} not unlocked: ${words}'
	app.diag_set_status(gen, st)
	return DiagOut{
		line: '${step}: ${words}'
		err:  true
	}, ecu_answered
}

// diag_unlock_request serves the General tab's Unlock and Lock.
fn (mut app App) diag_unlock_request(gen u64, mut h HeldConn, req DiagReq) (DiagOut, bool) {
	if req.kind == 'lock' {
		out, negative := app.diag_session_change(gen, mut h, diaghold.default_session)
		if out.err {
			return out, negative
		}
		return DiagOut{
			line: 'security locked: the default session serves no 0x27'
		}, false
	}
	to := diaghold.unlock_session(h.session)
	if to != 0 {
		out, negative := app.diag_session_change(gen, mut h, to)
		if out.err {
			return out, negative
		}
		app.diag_say_for(req, 'for 0x27, which the default session does not serve', false)
	}
	return app.diag_unlock(gen, mut h, req.level)
}

// unlock_level is the level the selector shows for `t`: the operator's pick for this target, else
// the lowest level its description's gates name, else 1.
fn (mut app App) unlock_level(t DiagTarget, desc DiagDesc) int {
	if app.unlock_ui.key != t.key || app.unlock_ui.ident != desc.ident || app.unlock_ui.level < 1
		|| app.unlock_ui.level > sysview.max_security_level {
		levels := if desc.ok { desc.desc.security_levels() } else { []int{} }
		app.unlock_ui = UnlockUi{
			key:   t.key
			ident: desc.ident
			level: int(diaghold.unlock_level_default(levels, sysview.max_security_level))
		}
	}
	return app.unlock_ui.level
}

// unlock_press sends Unlock at `level` for the selected target `t`, unless its description says
// its key is one the panel cannot compute (diaghold.unlock_refusal): refused then, nothing sent.
fn (mut app App) unlock_press(t DiagTarget, desc DiagDesc, level int) {
	why := diaghold.unlock_refusal(desc.ok && desc.desc.server, desc.ok
		&& desc.desc.security_key == 'reference')
	if why != '' {
		app.diag_push_refusal(t.key, t.label, 'Unlock level ${level}: ${why}')
		return
	}
	app.diag_send(DiagReq{
		kind:  'unlock'
		level: u8(level)
	})
}

// draw_unlock is the General tab's security row: the level, Unlock and Lock.
fn draw_unlock(mut app App, t DiagTarget, busy bool, st DiagHoldStatus) {
	desc := app.diag_desc(t)
	level := app.unlock_level(t, desc)
	vgui.align_text_to_frame_padding()
	vgui.text('security')
	vgui.same_line()
	vgui.set_next_item_width(110 * app.prefs.ui_scale)
	labels := []string{len: sysview.max_security_level, init: 'level ${index + 1}'}
	app.unlock_ui.level = vgui.combo('##unlocklevel', labels, level - 1) + 1
	sub := diaghold.seed_sub(u8(app.unlock_ui.level))
	vgui.set_item_tooltip('The 0x27 level: level L is requestSeed 0x${sub:02X} and sendKey 0x${sub + 1:02X} (2L-1 / 2L), as blobly_emb\'s ecu.toml numbers them.')
	vgui.same_line()
	if app.diag_button('Unlock') && !busy {
		app.unlock_press(t, desc, app.unlock_ui.level)
	}
	vgui.set_item_tooltip('Switch to the extended session if the connection is in the default one (0x27 is not served there), then request a seed and answer it with blobly_net\'s reference key (seed XOR FF). An all-zero seed means the level is already unlocked. Only a blobly_emb node with [uds] security_key = "reference" accepts that key.')
	vgui.same_line()
	if app.diag_button('Lock') && !busy {
		app.diag_press('lock', u16(0))
	}
	vgui.set_item_tooltip(diaghold.lock_words)
	if st.conn == .held && st.key == t.key && st.security != 0 {
		vgui.same_line()
		vgui.text_colored(230, 180, 60, 'level ${st.security} unlocked')
	}
	if desc.ok && desc.desc.server && desc.desc.security_key != 'reference' {
		vgui.text_dim_wrapped('${desc.node}\'s description names no reference key: its key is the OEM\'s, which the panel cannot compute — Unlock is refused; a script can unlock it with its key function')
	}
}
