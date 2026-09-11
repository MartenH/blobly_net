module main

import os
import time
import vgui

// TextFile is a file edited in place in an ImGui text box: the Configuration File tab's project
// text, and the Script panel's script (#270). ONE state machine for both — which path the
// buffer holds, whether it has been typed in since, what a read or a save said — because the
// second editor started as a copy of the first and had diverged on the day it landed (a
// different cap, a different invalidation, a different answer to an unreadable file). The
// rules here were each a review finding on the File tab once; a fix lands once now.
struct TextFile {
mut:
	buf          []u8   // the text, NUL-terminated, with room to type — ImGui writes into it and cannot grow it
	loaded       string // which path buf holds ('' = nothing loaded)
	dirty        bool   // typed in since it was loaded
	err          string // what holds a save back, or what a read said ('' = nothing)
	mtime        i64    // the file's modification time when it was loaded (stale)
	orig         string // the text as loaded: what write compares the file against, byte for byte
	disk_changed bool   // stale() answered yes while dirty: said until a load or a write
	seen         i64    // when stale last looked, ms — once a second, not per frame
}

// LoadOutcome is what load did: nothing (cached, or unsaved edits kept), a read, or a failure.
enum LoadOutcome {
	cached
	read
	failed
}

// load reads `path` into the buffer — once per path, because the tabs call this every frame
// and a re-read whenever the buffer was clean meant a synchronous file read and a 64 KiB
// allocation at frame rate. Freshness is invalidate() at every path that rewrites or replaces
// the file. Never over unsaved edits: a dirty buffer keeps its file, whatever the caller's path
// says now, until write() or invalidate(). A path that cannot be read is marked loaded all the
// same, so a missing file is not retried at frame rate; invalidate() retries it.
fn (mut tf TextFile) load(path string) LoadOutcome {
	// `buf.len > 0`: a buffer never allocated is not the loaded empty path — the box draws
	// nothing for it, with nothing on screen to say why.
	// A clean buffer whose file changed on disk — Open in editor, a checkout — is re-read; a
	// dirty one is kept and the strip says so (codex #307 r14).
	if tf.loaded == path && !tf.dirty && tf.buf.len > 0 && tf.stale() {
		tf.invalidate()
	}
	if (tf.loaded == path && tf.buf.len > 0) || tf.dirty {
		return .cached
	}
	txt := os.read_file(path) or {
		// Still allocate: the box is drawn regardless, and ImGui cannot be handed a
		// zero-capacity buffer.
		tf.buf = mkbuf('', 4096)
		tf.loaded = path
		tf.dirty = false
		tf.err = 'cannot read ${path}: ${err}'
		return .failed
	}
	// Generous headroom: ImGui writes into this buffer and cannot grow it, so the room to type
	// has to be reserved up front. The fill level is shown once it gets close.
	cap := if txt.len * 3 > 65536 { txt.len * 3 } else { 65536 }
	tf.buf = mkbuf(txt, cap)
	tf.loaded = path
	tf.dirty = false
	tf.err = ''
	tf.mtime = os.file_last_mod_unix(path)
	tf.orig = txt
	tf.seen = time.ticks()
	tf.disk_changed = false
	return .read
}

// stale reports whether the loaded file has changed on disk since it was read — asked at most
// once a second, since a stat per frame is a syscall per frame for every open editor.
fn (mut tf TextFile) stale() bool {
	if tf.loaded == '' {
		return false
	}
	now := time.ticks()
	if now - tf.seen < 1000 {
		return false
	}
	tf.seen = now
	return os.file_last_mod_unix(tf.loaded) != tf.mtime
}

// invalidate drops the cached text, so the next load re-reads it. Called wherever the file or
// the path changes underneath the editor — and by Reload, because clearing the dirty flag alone
// leaves the cache holding the edits.
fn (mut tf TextFile) invalidate() {
	tf.loaded = ''
	tf.dirty = false
	// And the text: with `loaded` at '' a retained buffer reads as the empty path, loaded and
	// clean — File ▸ New after an open project showed the old project's YAML that way, with
	// Reload agreeing (codex #305 r1).
	tf.buf = []u8{}
}

// text is what the box holds now.
fn (tf &TextFile) text() string {
	return vgui.buf_str(tf.buf)
}

// write puts the buffer back into the file it was LOADED from — that one, not whatever a path
// field says now — and marks it clean.
fn (mut tf TextFile) write() ! {
	// The file is checked NOW, not on the once-a-second cadence the strip uses: an external save
	// inside that second would be overwritten unseen (codex #307 r15). Refused once — the strip
	// has the warning by the next frame — and a Save pressed with the warning showing overwrites.
	// By CONTENT, not by the second-resolution mtime: an external save inside the same second
	// as the load is invisible to the stamp (codex #307 r16). A file that cannot be read now is
	// not a change this can judge; the write proceeds.
	now_txt := os.read_file(tf.loaded) or { tf.orig }
	if !tf.disk_changed && now_txt != tf.orig {
		tf.disk_changed = true
		return error('changed on disk since it was loaded — Discard edits takes the file, Save again overwrites it')
	}
	os.write_file(tf.loaded, tf.text())!
	tf.dirty = false
	tf.err = ''
	tf.mtime = os.file_last_mod_unix(tf.loaded)
	tf.orig = tf.text()
	tf.disk_changed = false
}

// TextFileAct is what the strip's buttons asked for this frame.
enum TextFileAct {
	none
	save
	reload
	external
}

// draw_textfile_strip is the two rows above an edit box. First the FILE — `shown`, which is
// the path or why the editor is on something else, and the modified mark — on its own line,
// where a dim path after the buttons was easy to lose (#306). Then the buttons: Save (offered
// only when `can_save` — vgui has no disabled scope, so a withheld action is a dim
// placeholder); "Discard edits" while dirty, "Reload" when clean — one action, re-read the
// file, named for what it does now; and, when `external`, "Open in editor". Then the fill
// level once the buffer is nearly full, and the file's error. The caller acts on the result.
fn draw_textfile_strip(mut tf TextFile, id string, save_label string, can_save bool, shown string, external bool) TextFileAct {
	mut act := TextFileAct.none
	if tf.dirty && tf.stale() {
		tf.disk_changed = true // its own line below, not `err`: the File tab's Save is gated on err
	}
	if tf.disk_changed {
		vgui.text_colored(230, 170, 70,
			'changed on disk since it was loaded — Discard edits takes the file, Save overwrites it')
	}
	vgui.text_dim('file:')
	vgui.same_line()
	vgui.text(shown)
	if tf.dirty {
		vgui.same_line()
		vgui.text_colored(230, 170, 70, '● modified')
	}
	if can_save {
		if vgui.button('${save_label}##${id}') {
			act = .save
		}
	} else {
		vgui.text_dim('[ Save ]')
	}
	vgui.same_line()
	if vgui.button(if tf.dirty { 'Discard edits##${id}' } else { 'Reload##${id}' }) {
		act = .reload
	}
	if external {
		vgui.same_line()
		if vgui.button('Open in editor##${id}') {
			act = .external
		}
	}
	// buf_len, not buf_str: a copy of the whole text every frame to learn its length.
	used := vgui.buf_len(tf.buf)
	if used > tf.buf.len - 1024 {
		vgui.text_colored(230, 120, 120,
			'buffer nearly full (${used}/${tf.buf.len}) — Save, then Reload for more room')
	}
	if tf.err != '' {
		vgui.text_colored(230, 120, 120, tf.err)
	}
	return act
}
