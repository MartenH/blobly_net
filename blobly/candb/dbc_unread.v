// dbc_unread — the DBC records parse_dbc does not take, counted by kind, so a load can say what
// of a file it did not use (`SIG_VALTYPE_ × 3`, `attribute "GenSigSendType" × 40`). What reaches
// `see` is every line no reader took; what is not a record of the file's content is left out:
// the VERSION label, the NS_ symbol list and the BS_ line, an attribute's definition (BA_DEF_,
// BA_DEF_REL_ — it states nothing about an object), every comment (CM_ — on the network, a
// node, a message, a signal or an env var: none changes a decode or the simulation) and the
// inside of a string running over several lines.
module candb

// Unread is the tally while a file is read.
struct Unread {
mut:
	order  []string
	counts map[string]int
	in_ns  bool // inside the NS_ list, whose entries are indented keyword names
	in_str bool // inside a quoted string running over lines
	cont   bool // the current line began inside such a string
}

// begin is told every line before it is dispatched.
fn (mut u Unread) begin(raw string, line string) {
	u.cont = u.in_str
	if u.in_ns && line != '' && !raw.starts_with(' ') && !raw.starts_with('\t') {
		u.in_ns = false
	}
}

// end is told every line after it is dispatched: a line with an odd number of unescaped quotes
// opens or closes a string that runs over lines.
fn (mut u Unread) end(line string) {
	mut quotes := 0
	for i, c in line {
		if c == `"` && (i == 0 || line[i - 1] != `\\`) {
			quotes++
		}
	}
	if quotes % 2 == 1 {
		u.in_str = !u.in_str
	}
}

// see counts a line no reader took, by its kind.
fn (mut u Unread) see(line string) {
	if u.cont || u.in_ns || line == '' || line.starts_with('//') {
		return
	}
	f := line.fields()
	kw := f[0].trim_right(':')
	if kw == 'NS_' {
		u.in_ns = true
		return
	}
	if kw in ['VERSION', 'BS_', 'BA_DEF_', 'BA_DEF_REL_', 'CM_'] || !is_keyword(kw) {
		return
	}
	kind := match kw {
		'BA_', 'BA_REL_', 'BA_DEF_DEF_', 'BA_DEF_DEF_REL_' {
			if f.len < 2 {
				kw
			} else {
				'attribute ${f[1]}'
			}
		}
		else {
			kw
		}
	}
	if kind !in u.counts {
		u.order << kind
	}
	u.counts[kind]++
}

// is_keyword is whether a token is shaped like a DBC record keyword: capitals, digits and
// underscores, at least two of them.
fn is_keyword(t string) bool {
	return t.len >= 2 && t.bytes().all(it == `_` || (it >= `A` && it <= `Z`) || (it >= `0`
		&& it <= `9`))
}

// lines is the tally in file order, one entry per kind.
fn (u Unread) lines() []string {
	return u.order.map('${it} × ${u.counts[it]}')
}
