# mut_alias.awk — a local alias of a `mut` receiver or parameter, which is a COPY under V3.
#
# Inside `fn (mut app App) f()` (or `fn f(mut app App)`), `ap := app` copies the struct (measured
# on V 0535623): the alias has its own address, a closure capturing it holds another copy, and a
# pointer taken from it points at whatever stack it lives on. `ap := &app`, `fn [app]`,
# `spawn g(app)` and `mut ap := unsafe { app }` all reach the receiver, and are not reported.
# diag_attach's `ap := app`, opened on another thread, left a tap pointing into a dead stack and
# the CAN diagnostic press crashed (docs/known_issues.md).
#
# A lint over V text, not a parser, so its model is stated here and its fixtures are
# mut_alias_test.sh:
#   SCOPE   a top-level `fn` whose signature (continuation lines included) declares `mut NAME T`
#           opens a scope for NAME; it ends when the body's braces close, so top-level code after
#           it is not in it. A nested `fn (...)` / `fn [...] (...)` literal's own parameters —
#           any of them, pointer or value — hide the outer names until the literal's body closes.
#   UNIT    a STATEMENT: the text between `{`, `}` and `;` (strings and the trailing comment
#           removed), so `if ok { copy := app }` and `fn f() { copy := app }` are both seen.
#   REPORT  a statement that is exactly `[mut] x := NAME` or `x = NAME`, as `FILE:LINE: TEXT`.
#           A snapshot that is meant says `// copy:` in its line's comment (not in a string).
#   LIMITS  known and accepted, since `v fmt` writes neither and the repo has neither:
#           - a nested literal and a LATER outer statement on one line
#             (`{ fn (app App) {}(app); copy := app }`) — the literal hides `app` for the whole
#             line, so that copy is missed;
#           - a nested literal whose parameter list spans lines (`fn (n int,` / `app App) {`)
#             only shadows from its first line, so a copy of that value parameter is reported —
#             loudly, and `// copy:` silences it.
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

# a line with its string literals emptied — an escaped quote (`'don\'t }'`) stays inside its string
function unquoted(line,    s) {
	s = line
	gsub(/'([^'\\]|\\.)*'/, "''", s)
	gsub(/"([^"\\]|\\.)*"/, "\"\"", s)
	gsub(/`([^`\\]|\\.)*`/, "``", s)
	return s
}

# what braces and statements are read from: no strings, no trailing comment
function code(line,    s) {
	s = unquoted(line)
	sub(/\/\/.*$/, "", s)
	return s
}

# the snapshot marker counts only in the line's COMMENT, never inside a string
function marked_copy(line,    s, k) {
	s = unquoted(line)
	k = index(s, "//")
	return k > 0 && substr(s, k) ~ /^\/\/ copy:/
}

function brace_delta(s,    o, c) {
	o = gsub(/\{/, "{", s)
	c = gsub(/\}/, "}", s)
	return o - c
}

# a nested fn literal's own parameters hide the outer names until its body closes: each one that
# is a watched name is pushed with the depth the literal starts at, and comes back when the depth
# falls to it again. Every parameter, pointer or value: `fn (app App)` hides `app` as surely as
# `fn (app &App)` does.
function shadow(s,    plist, n, i, p, w, name) {
	plist = s
	sub(/^.*fn[ \t]*(\[[^]]*\][ \t]*)?\(/, "", plist)
	sub(/\).*$/, "", plist)
	n = split(plist, p, ",")
	for (i = 1; i <= n; i++) {
		w = p[i]
		sub(/^[ \t]*(mut[ \t]+)?/, "", w)
		match(w, /^[A-Za-z_][A-Za-z0-9_]*/)
		if (RLENGTH <= 0) {
			continue
		}
		name = substr(w, 1, RLENGTH)
		if (name in muts) {
			nsh++
			sh_name[nsh] = name
			sh_depth[nsh] = depth
			delete muts[name]
		}
	}
}

function restore() {
	while (nsh > 0 && depth <= sh_depth[nsh]) {
		muts[sh_name[nsh]] = 1
		nsh--
	}
}

# every statement of a line (or of the part of it after a signature's opening brace)
function check(raw, s,    n, i, parts, st, name) {
	if (marked_copy(raw)) {
		return
	}
	n = split(s, parts, /[{};]/)
	for (i = 1; i <= n; i++) {
		st = parts[i]
		for (name in muts) {
			if (st ~ "^[ \t]*(mut[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*:?=[ \t]*" name "[ \t]*$") {
				print FILENAME ":" FNR ": " raw
				return
			}
		}
	}
}

function end_fn() {
	delete muts
	nsh = 0
	depth = 0
	in_fn = 0
}

FNR == 1 { end_fn(); in_sig = 0 }
/^(pub )?fn / {
	end_fn()
	in_sig = 1
	sig = ""
}
in_sig {
	# a signature runs to its body's opening brace: at the end of a line, or followed by the
	# body on that same line (`fn (mut app App) f() { copy := app }`)
	c = code($0)
	sig = sig " " c
	k = index(c, "{")
	if (k > 0) {
		in_sig = 0
		in_fn = 1
		collect(sig)
		rest = substr(c, k + 1)
		if (rest ~ /fn[ \t]*(\[[^]]*\][ \t]*)?\(/) {
			shadow(rest)
		}
		check($0, rest)
		depth = brace_delta(c)
		restore()
		if (depth <= 0) {
			end_fn()
		}
	}
	next
}
in_fn {
	c = code($0)
	if (c ~ /fn[ \t]*(\[[^]]*\][ \t]*)?\(/) {
		shadow(c)
	}
	check($0, c)
	depth += brace_delta(c)
	restore()
	# the outermost body closed: what follows is top-level, in no fn's scope
	if (depth <= 0) {
		end_fn()
	}
}
