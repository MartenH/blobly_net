#!/bin/sh
# check_mut_refs.sh — refuse the two spellings that COPY a `mut` receiver in V (docs/known_issues.md).
#
# Inside `fn (mut app App) f()`, `ap := &app` binds a COPY of the struct, and so does a closure
# capturing it by value, `fn [app] ...`; `a := app` (a reference) and `fn [mut app]` do not. A copy
# handed to anything that outlives the call carries its own mutex over the caller's maps — the
# Diagnostics panel crash after #402. The compiler accepts both, and the GUI has no tests, so this
# grep is what stops the next one. Run by check_cmds.sh, so CI runs it on both jobs.
set -u
cd "$(dirname "$0")/.." || exit 2
found=$(find cmd modules -name '*.v' ! -name '*_test.v' | sort | xargs awk '
	FNR == 1 { recv = "" }
	/^fn \(mut [A-Za-z_][A-Za-z0-9_]* / {
		recv = $3 # fn (mut app App): $2 is "(mut", $3 the name of the receiver
		next
	}
	/^fn / { recv = ""; next }
	recv != "" {
		line = $0
		if (line ~ ("(:=|=) *&" recv "[ \t]*$")) {
			printf "%s:%d: binds &%s, a copy of the mut receiver\n", FILENAME, FNR, recv
		}
		while (match(line, /fn \[[^]]*\]/)) {
			caps = substr(line, RSTART + 4, RLENGTH - 5)
			line = substr(line, RSTART + RLENGTH)
			n = split(caps, c, ",")
			for (i = 1; i <= n; i++) {
				gsub(/^[ \t]+|[ \t]+$/, "", c[i])
				if (c[i] == recv) {
					printf "%s:%d: closure captures %s by value, a copy of the mut receiver (bind a := %s first, or capture mut %s)\n", FILENAME, FNR, recv, recv, recv
				}
			}
		}
	}
')
if [ -n "$found" ]; then
	printf '%s\n' "$found"
	exit 1
fi
echo 'check_mut_refs: no copied mut receivers'
