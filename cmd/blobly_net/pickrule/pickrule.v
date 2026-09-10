module pickrule

// THE FILE PICKER'S TWO DECISIONS, AS RULES. What a click on a row does, and where "up" goes
// from a folder — the two places #270 found the picker wrong: it ENTERED a folder on a single
// click, so the hand that double-clicks (every native picker's habit) landed its second click
// on a row of the folder it had just entered; and above a Windows drive root it had nowhere to
// go, so `D:` could not be reached from `C:` at all. Pure functions over strings and flags, in
// the shape ../saverule and ../taprule set: the GUI calls them, and the scenarios are the test.

// Entry is what kind of row was acted on.
pub enum Entry {
	dir
	file
}

// Act is what the picker does in response.
pub enum Act {
	select // highlight the row; nothing else moves
	enter  // navigate into the folder
	accept // hand the file to the pending action
}

// action decides a click on a row of kind `e`: a single click SELECTS, whatever the row is; a
// double click ENTERS a folder or ACCEPTS a file. The Open button and the Enter key act on the
// selected row the way a double click does — `activate` below — so the three spellings of
// "go" agree by construction. In SAVE mode a file is never accepted this way: the picker has
// no "replace?" prompt, so a double click that overwrote would be the one destructive act in
// the app with no confirmation; the click selects, the name field takes the name, and only the
// Save button writes.
pub fn action(e Entry, double bool, save bool) Act {
	if !double {
		return .select
	}
	return activate(e, save)
}

// activate is Enter / Open on a row of kind `e`.
pub fn activate(e Entry, save bool) Act {
	if e == .dir {
		return .enter
	}
	return if save { Act.select } else { Act.accept }
}

// drives is the folder value that means "list the drive roots" — the level ABOVE a Windows
// drive root. Windows has no single root: `C:\\` and `D:\\` are siblings with no parent, so the
// picker gives them one. On Linux `/` is its own parent and this level is never reached.
pub const drives = ''

// is_drive_root reports whether `dir` spells a Windows drive root: `C:`, `C:\\` or `C:/`, any
// letter, either case. Nothing else counts — `C:\\x` is a folder, `\\server\\share` is not a
// drive (and is walked like a folder: its parent is itself).
pub fn is_drive_root(dir string) bool {
	if dir.len < 2 || dir.len > 3 || dir[1] != `:` {
		return false
	}
	c := dir[0]
	is_letter := (c >= `a` && c <= `z`) || (c >= `A` && c <= `Z`)
	if !is_letter {
		return false
	}
	return dir.len == 2 || dir[2] == `\\` || dir[2] == `/`
}

// parent is where ".. up" goes from `dir`. On Windows a drive root goes to `drives`; a folder
// directly under a root goes to the root spelled `X:\\` (not the bare `X:`, which the OS reads
// as "the current directory on X", a different place); `drives` stays where it is. On Linux `/`
// stays `/`. A path with no separator at all — a bare relative name — is its own parent, so a
// picker opened on `projects` cannot climb out of what it was given by `..`; the typed path is
// the way there. Trailing separators are ignored (`D:\\ems2\\` is `D:\\ems2`).
pub fn parent(dir string, windows bool) string {
	if dir == drives {
		return drives
	}
	if windows && is_drive_root(dir) {
		return drives
	}
	mut d := dir
	for d.len > 1 && (d[d.len - 1] == `\\` || d[d.len - 1] == `/`) {
		d = d[..d.len - 1]
	}
	if windows && is_drive_root(d) {
		return drives
	}
	mut cut := -1
	for i := d.len - 1; i >= 0; i-- {
		if d[i] == `\\` || d[i] == `/` {
			cut = i
			break
		}
	}
	if cut < 0 {
		return d
	}
	if cut == 0 {
		return d[..1] // `/x` -> `/`
	}
	up := d[..cut]
	if windows && is_drive_root(up) {
		return up[..2] + '\\'
	}
	return up
}
