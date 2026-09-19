module pickrule

// THE FILE PICKER'S THREE DECISIONS, AS RULES. What a click on a row does, what a double click,
// Enter and Open do, and where "up" goes from a folder. Pure functions over strings and flags,
// in the shape ../saverule and ../taprule set: the GUI calls them, and the scenarios are the
// test. #270 found the picker wrong twice: it ENTERED a folder on a single click, so the hand
// that double-clicks (every native picker's habit) landed its second click on a row of the
// folder it had just entered; and above a Windows drive root it had nowhere to go, so `D:`
// could not be reached from `C:` at all. #270 answered the first by making a click SELECT
// only. The single click is BACK — it is how VS Code's picker moves, and one click per folder
// is what a hand navigating a tree wants — and the hazard is answered where it lives instead:
// the second click of a double is recognised as one (`click`), and ignored when the first
// click entered a folder.

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
	ignore // a click the hand did not aim: the second of a double, after the first entered a folder
}

// activate is what a double click, the Enter key and the Open button do to a row of kind `e`
// — one rule, so the three spellings of "go" agree by construction: a folder is ENTERED, a
// file ACCEPTED. In SAVE mode a file is never accepted this way: the picker has no "replace?"
// prompt, so a double click that overwrote would be the one destructive act in the app with
// no confirmation; the row selects, the name field takes the name, and only the Save button
// (or Enter in the name field) writes.
pub fn activate(e Entry, save bool) Act {
	if e == .dir {
		return .enter
	}
	return if save { Act.select } else { Act.accept }
}

// Burst is the click-burst state the click rule needs: whether the LISTING WAS REPLACED since
// the burst began. ImGui counts presses within its double-click time and distance (300 ms and
// 6 px by default) as one burst, `press` is told every press with its number in the burst
// (1 for a lone click, 2 for the second of a double), and `listing_replaced` is told every
// replacement of the listing — by a row, the drive dropdown, `.. up`, a typed path or the menu
// that opened the picker under the pointer; the GUI says it in the ONE place the listing is
// replaced, so no entry path can be missed. A selectable reports on the RELEASE, when the
// burst's last press still names it, which is why the count is kept rather than asked.
pub struct Burst {
pub mut:
	count    int  // presses in the current burst, as of its last press
	replaced bool // the listing was replaced since this burst's first press
}

// press is every frame's answer to "how many presses is this one?" — 0 on a frame with no
// press (ImGui's GetMouseClickedCount), which changes nothing. The first press of a burst
// begins it: what an earlier burst replaced is not this one's doing.
pub fn (mut b Burst) press(n int) {
	if n <= 0 {
		return
	}
	b.count = n
	if n == 1 {
		b.replaced = false
	}
}

// listing_replaced is what the picker says whenever the rows change under the pointer.
pub fn (mut b Burst) listing_replaced() {
	b.replaced = true
}

// click is what ONE CLICK on a row of kind `e` does. A lone click ENTERS a folder and SELECTS
// a file. The second or later click of a burst whose listing was replaced is #270's hand: it
// double-clicked a folder, the first click entered it, and the second lands on whatever row of
// the new listing sits under the mouse. It is IGNORED whatever that row is — a folder there
// would be entered, a file there opened, and neither was aimed at. A second click whose burst
// replaced nothing is a real double click and does what Enter and Open do (activate: accept,
// or select in save mode). The price is stated in the manual: a click on the same spot within
// the burst window of one that entered a folder does nothing, so a hand descending a tree by
// the top row faster than that loses every second click.
pub fn (b Burst) click(e Entry, save bool) Act {
	if b.count >= 2 {
		if b.replaced {
			return .ignore
		}
		return activate(e, save)
	}
	if e == .dir {
		return .enter
	}
	return .select
}

// drives is the folder value that means "list the drive roots" — the level ABOVE a Windows
// drive root. Windows has no single root: `C:\` and `D:\` are siblings with no parent, so the
// picker gives them one. On Linux `/` is its own parent and this level is never reached.
pub const drives = ''

// is_drive_root reports whether `dir` spells a Windows drive root: `C:`, `C:\` or `C:/`, any
// letter, either case. Nothing else counts — `C:\x` is a folder, and a UNC share is not a
// drive (is_unc_root).
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

// is_unc_root reports whether `dir` is a UNC share root — `\\server\share` (either separator),
// or the bare `\\server` — the shape a Windows share is reached by. Its parent is not a place
// a file picker can list, so it is its own (codex #305 r1).
pub fn is_unc_root(dir string) bool {
	if dir.len < 3 {
		return false
	}
	sep := fn (c u8) bool {
		return c == `\\` || c == `/`
	}
	if !sep(dir[0]) || !sep(dir[1]) {
		return false
	}
	mut parts := 0
	mut in_part := false
	for i := 2; i < dir.len; i++ {
		if sep(dir[i]) {
			if !in_part {
				return false // an empty component: not a share root
			}
			in_part = false
		} else if !in_part {
			in_part = true
			parts++
		}
	}
	return in_part && parts <= 2
}

// parent is where ".. up" goes from `dir`. On Windows a drive root goes to `drives`; a folder
// directly under a root goes to the root spelled `X:\` (not the bare `X:`, which the OS reads
// as "the current directory on X", a different place); `drives` stays where it is. On Linux `/`
// stays `/`. A UNC share root (`\\server\share`, is_unc_root) is its own parent: the level above
// a share is not a folder this picker can list. A path with no separator at all — a bare relative name — is its own parent, so a
// picker opened on `projects` cannot climb out of what it was given by `..`; the typed path is
// the way there. Trailing separators are ignored (`D:\ems2\` is `D:\ems2`).
pub fn parent(dir string, windows bool) string {
	mut d := dir
	for d.len > 1 && (d[d.len - 1] == `\\` || d[d.len - 1] == `/`) {
		d = d[..d.len - 1]
	}
	if windows && is_drive_root(d) {
		return drives
	}
	if windows && is_unc_root(d) {
		return d
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
