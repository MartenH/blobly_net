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
# where NAME is a `mut` receiver or parameter of the enclosing fn — its signature read whole,
# continuation lines included. A nested `fn (...)` / `fn [...]` literal re-declaring NAME
# (`app &App`) hides it for the literal's BODY only (brace depth), not for the rest of the fn.
# A copy that is meant (a snapshot) says so with `// copy:` on its line.
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

# braces opened minus closed on a line, outside string literals and the trailing comment
function brace_delta(line,    s, o, c) {
	s = line
	gsub(/'[^']*'/, "", s)
	gsub(/"[^"]*"/, "", s)
	gsub(/`[^`]*`/, "", s)
	sub(/\/\/.*$/, "", s)
	o = gsub(/\{/, "{", s)
	c = gsub(/\}/, "}", s)
	return o - c
}

# a nested fn literal's own pointer parameters hide the outer names until its body closes:
# push them with the depth the literal starts at; they come back when depth falls to it again
function shadow(line,    s, frag, parts, name) {
	s = line
	sub(/^.*fn[ \t]*(\[[^]]*\][ \t]*)?\(/, "", s)
	while (match(s, /[A-Za-z_][A-Za-z0-9_]* &/)) {
		frag = substr(s, RSTART, RLENGTH)
		split(frag, parts, " ")
		name = parts[1]
		if (name in muts) {
			nsh++
			sh_name[nsh] = name
			sh_depth[nsh] = depth
			delete muts[name]
		}
		s = substr(s, RSTART + RLENGTH)
	}
}

function restore(    k) {
	while (nsh > 0 && depth <= sh_depth[nsh]) {
		muts[sh_name[nsh]] = 1
		nsh--
	}
}

function start_fn() {
	delete muts
	nsh = 0
	depth = 0
	in_sig = 1
	sig = ""
}

FNR == 1 { delete muts; nsh = 0; depth = 0; in_sig = 0 }
/^(pub )?fn / { start_fn() }
in_sig {
	# a signature runs until the line that opens the body
	sig = sig " " $0
	if ($0 ~ /\{[ \t]*$/ || $0 ~ /\{[ \t]*\/\//) {
		in_sig = 0
		collect(sig)
		depth = brace_delta($0)
	}
	next
}
{
	if ($0 ~ /fn[ \t]*(\[[^]]*\][ \t]*)?\(/) {
		shadow($0)
	}
	if ($0 !~ /\/\/ copy:/) {
		line = $0
		sub(/[ \t]*\/\/.*$/, "", line)
		for (name in muts) {
			if (line ~ "^[ \t]*(mut )?[A-Za-z_][A-Za-z0-9_]*[ \t]*:?=[ \t]*" name "[ \t]*$") {
				print FILENAME ":" FNR ": " $0
			}
		}
	}
	depth += brace_delta($0)
	restore()
}
