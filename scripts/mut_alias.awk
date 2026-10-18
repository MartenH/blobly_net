# mut_alias.awk — a local alias of a `mut` receiver or parameter, which is a COPY under V3.
#
# Inside `fn (mut app App) f()` (or `fn f(mut app App)`), `ap := app` copies the struct (measured
# on V 0535623): the alias has its own address, a closure capturing it holds another copy, and a
# pointer taken from it points at whatever stack it lives on. `ap := &app`, `fn [app]`,
# `spawn g(app)` and `mut ap := unsafe { app }` all reach the receiver, and are not reported.
# diag_attach's `ap := app`, opened on another thread, left a tap pointing into a dead stack and
# the CAN diagnostic press crashed (docs/known_issues.md).
#
# Reports `FILE:LINE: TEXT` for `[mut] x := NAME` and `x = NAME`, a trailing comment allowed,
# where NAME is a `mut` receiver or parameter of the enclosing fn. A nested `fn (...)` / `fn [...]`
# re-declaring NAME (`app &App`) takes it out of scope; it is a pointer there. A copy that is
# meant (a snapshot) says so with `// copy:` on its line.
#
#   find cmd blobly ... -name '*.v' | xargs awk -f scripts/mut_alias.awk

function collect(sig,    s, frag, parts) {
	s = sig
	while (match(s, /mut [A-Za-z_][A-Za-z0-9_]* [&A-Za-z_\[]/)) {
		frag = substr(s, RSTART + 4, RLENGTH - 4)
		split(frag, parts, " ")
		muts[parts[1]] = 1
		s = substr(s, RSTART + RLENGTH)
	}
}

# a nested fn literal's own parameters shadow the outer names: `fn (app &App, w W)` makes `app` a
# pointer for the rest of the enclosing fn's text, which is close enough for a lint on aliases
function shadow(line,    s, frag, parts) {
	s = line
	sub(/^.*fn[ \t]*(\[[^]]*\][ \t]*)?\(/, "", s)
	while (match(s, /[A-Za-z_][A-Za-z0-9_]* &/)) {
		frag = substr(s, RSTART, RLENGTH)
		split(frag, parts, " ")
		delete muts[parts[1]]
		s = substr(s, RSTART + RLENGTH)
	}
}

FNR == 1 { delete muts }
/^(pub )?fn / {
	delete muts
	collect($0)
	next
}
/fn[ \t]*(\[[^]]*\][ \t]*)?\(/ { shadow($0) }
/\/\/ copy:/ { next }
{
	line = $0
	sub(/[ \t]*\/\/.*$/, "", line)
	for (name in muts) {
		if (line ~ "^[ \t]*(mut )?[A-Za-z_][A-Za-z0-9_]*[ \t]*:?=[ \t]*" name "[ \t]*$") {
			print FILENAME ":" FNR ": " $0
		}
	}
}
