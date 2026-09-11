module main

import os

#include <windows.h>
#include <shellapi.h>
#flag windows -lshell32

fn C.ShellExecuteW(hwnd voidptr, op &u16, file &u16, params &u16, dir &u16, show int) voidptr

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
// space, an inner quote escaped.
fn quote_arg(a string) string {
	if a == '' {
		return '""'
	}
	if !a.contains(' ') && !a.contains('"') {
		return a
	}
	return '"' + a.replace('"', '\\"') + '"'
}
