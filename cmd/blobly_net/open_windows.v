module main

import os

#include <windows.h>
#include <shellapi.h>
#flag windows -lshell32

fn C.ShellExecuteW(hwnd voidptr, op &u16, file &u16, params &u16, dir &u16, show int) voidptr
fn C.MoveFileExW(src &u16, dst &u16, flags u32) int
fn C.OpenProcess(access u32, inherit int, pid u32) voidptr

// system_open opens `path` with whatever the desktop associates with it — ShellExecute's
// "open", with its verdict CHECKED: a return above 32 is a launch, anything else is why not.
// vlib's os.open_uri discards that return, so through it a file nothing is associated with
// (a .lua on a fresh machine) "opened" while Windows showed its "how do you want to open
// this" box and the user cancelled (self-review on #307). `report` is unused here: on this
// platform the verdict is synchronous.
fn system_open(path string, report fn (string)) (bool, string) {
	r := shell_execute(unsafe { nil }, path, '')
	if r > 32 {
		return true, 'opened ${path}'
	}
	if r == 31 {
		return false, 'nothing is associated with ${os.file_ext(path)} files — set an editor in Settings ▸ Preferences…'
	}
	return false, 'the system could not open ${path} (ShellExecute ${r})'
}

// launch_detached runs `argv` without waiting for it, and NEVER through os.new_process: vlib's
// CreateProcess wrapper exits the WHOLE PROCESS when the command cannot start
// (failed_cfn_report_error → exit(1)), so a mistyped editor command would take the GUI and
// its run down with it. ShellExecute on the resolved executable instead; its verdict is
// immediate, so `report` is not needed here.
fn launch_detached(argv []string, report fn (string)) ! {
	exe := os.find_abs_path_of_executable(argv[0]) or {
		return error('${argv[0]}: not found on PATH — set the command in Settings ▸ Preferences…')
	}
	params := argv[1..].map(quote_arg(it)).join(' ')
	r := shell_execute('open'.to_wide(), exe, params)
	if r <= 32 {
		return error('${argv[0]} did not start (ShellExecute ${r})')
	}
}

fn shell_execute(op &u16, file string, params string) int {
	p := if params == '' { unsafe { &u16(nil) } } else { params.to_wide() }
	// SW_SHOWNORMAL = 1. The return is an HINSTANCE in name only: a value above 32 is success.
	return int(usize(C.ShellExecuteW(unsafe { nil }, op, file.to_wide(), p, unsafe { nil }, 1)))
}

// quote_arg spells one argument the way CommandLineToArgv reads it back: quoted when it has a
// space or a quote, with the rule that a run of backslashes BEFORE a quote (an inner one, or
// the closing one) is doubled, and a backslash elsewhere left alone — `C:\Editor Data\` must
// not end in a backslash that escapes its own closing quote (codex #307 r3).
fn quote_arg(a string) string {
	if a == '' {
		return '""'
	}
	if !a.contains(' ') && !a.contains('"') && !a.contains('\t') {
		return a
	}
	mut out := '"'
	mut bs := 0
	for c in a {
		if c == `\\` {
			bs++
			continue
		}
		if c == `"` {
			out += '\\'.repeat(bs * 2 + 1) + '"'
		} else {
			out += '\\'.repeat(bs) + c.ascii_str()
		}
		bs = 0
	}
	out += '\\'.repeat(bs * 2) + '"'
	return out
}

// replace_file moves `tmp` over `dst` in one step: MoveFileEx with REPLACE_EXISTING (and
// WRITE_THROUGH), since _wrename — what os.rename is here — refuses a target that exists, and
// os.mv then falls back to a copy, which is the truncate-then-write this exists to avoid.
fn replace_file(tmp string, dst string) ! {
	// MOVEFILE_REPLACE_EXISTING = 1, MOVEFILE_WRITE_THROUGH = 8
	if C.MoveFileExW(tmp.to_wide(), dst.to_wide(), u32(1 | 8)) == 0 {
		return error('could not replace ${dst} (MoveFileEx ${C.GetLastError()})')
	}
}

// process_alive reports whether `pid` is a running process: OpenProcess for its exit code, and
// STILL_ACTIVE (259) means running. A pid nothing answers for is dead — or not ours to ask,
// which for a lock a crashed instance of this app left is the same answer.
fn process_alive(pid int) bool {
	// PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
	h := C.OpenProcess(u32(0x1000), 0, u32(pid))
	if h == unsafe { nil } {
		return false
	}
	defer {
		C.CloseHandle(h)
	}
	mut code := u32(0)
	C.GetExitCodeProcess(h, &code)
	return code == 259
}
