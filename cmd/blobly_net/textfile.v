module main

import os
import vgui

// TextFile is a file edited in place in an ImGui text box: the Configuration File tab's project
// text, and the Script panel's script (#270). ONE state machine for both — which path the
// buffer holds, whether it has been typed in since, what a read or a save said — because the
// second editor started as a copy of the first and had diverged on the day it landed (a
// different cap, a different invalidation, a different answer to an unreadable file). The
// rules here were each a review finding on the File tab once; a fix lands once now.
struct TextFile {
mut:
	buf    []u8   // the text, NUL-terminated, with room to type — ImGui writes into it and cannot grow it
	loaded string // which path buf holds ('' = nothing loaded)
	dirty  bool   // typed in since it was loaded
	err    string // what holds a save back, or what a read said ('' = nothing)
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
	return .read
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
	os.write_file(tf.loaded, tf.text())!
	tf.dirty = false
	tf.err = ''
}

// TextFileAct is what the strip's buttons asked for this frame.
enum TextFileAct {
	none
	save
	reload
}

// draw_textfile_strip is the row above an edit box: Save (offered only when `can_save` — vgui
// has no disabled scope, so a withheld action is a dim placeholder) and Reload, the modified
// mark, `shown` (the file, or why the editor is on something else), the fill level once the
// buffer is nearly full, and the file's error. The caller acts on what it returns.
fn draw_textfile_strip(tf &TextFile, id string, save_label string, can_save bool, shown string) TextFileAct {
	mut act := TextFileAct.none
	if can_save {
		if vgui.button('${save_label}##${id}') {
			act = .save
		}
	} else {
		vgui.text_dim('[ Save ]')
	}
	vgui.same_line()
	if vgui.button('Reload##${id}') {
		act = .reload
	}
	if tf.dirty {
		vgui.same_line()
		vgui.text_colored(230, 170, 70, '● modified')
	}
	vgui.same_line()
	vgui.text_dim(shown)
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
