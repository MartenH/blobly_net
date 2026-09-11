module main

import os

#include <unistd.h>
#include <sys/wait.h>

fn C.fork() int
fn C.execv(path &char, argv &&char) int
fn C._exit(code int)
fn C.waitpid(pid int, status &int, options int) int
fn C.close(fd int) int
fn C.link(oldpath &char, newpath &char) int

// is_wsl reports whether we're under WSL, where no Linux browser or editor is around and the
// Windows side has to open the file.
fn is_wsl() bool {
	if os.getenv('WSL_DISTRO_NAME') != '' || os.getenv('WSL_INTEROP') != '' {
		return true
	}
	rel := os.read_file('/proc/sys/kernel/osrelease') or { return false }
	low := rel.to_lower()
	return low.contains('microsoft') || low.contains('wsl')
}

// system_open opens `path` with whatever the desktop associates with it. Under WSL that is the
// Windows side, through wslview (wslu) or explorer.exe with a wslpath UNC; elsewhere xdg-open.
// Nothing here WAITS on the GUI thread: xdg-open's generic fallback returns only when the
// application it launched exits, which for a text editor is the whole edit. A later failure
// (a nonzero exit) reaches `report` from the reaper thread.
fn system_open(path string, report fn (string)) (bool, string) {
	if is_wsl() {
		if exe := os.find_abs_path_of_executable('wslview') {
			// wslview's verdict comes from the reaper thread; a failure there falls back to
			// explorer.exe from that thread (codex #307 r18), so a broken wslu is not the end.
			fallback := fn [path, report] (msg string) {
				if exe2 := os.find_abs_path_of_executable('explorer.exe') {
					win := os.execute('wslpath -w ' + os.quoted_path(path))
					if win.exit_code == 0 {
						launch_detached([exe2, win.output.trim_space()], report) or {
							report('${msg}; explorer.exe: ${err.msg()}')
							return
						}
						report('${msg}; opened through explorer.exe instead')
						return
					}
				}
				report(msg)
			}
			launch_detached([exe, path], fallback) or { return false, err.msg() }
			return true, 'opened ${path} on the Windows side (wslview)'
		}
		if exe := os.find_abs_path_of_executable('explorer.exe') {
			// wslpath is a short synchronous conversion, not the launch
			win := os.execute('wslpath -w ' + os.quoted_path(path))
			if win.exit_code == 0 {
				launch_detached([exe, win.output.trim_space()], report) or {
					return false, err.msg()
				}
				return true, 'opened ${path} on the Windows side (explorer.exe)'
			}
		}
		return false, 'no way to open ${path} from WSL — install wslu for wslview, or set an editor in Settings ▸ Preferences…'
	}
	launch_detached(['xdg-open', path], report) or { return false, err.msg() }
	return true, 'opened ${path} (xdg-open)'
}

// launch_detached runs `argv` without waiting for it. Its own fork/exec rather than
// os.new_process, for two things vlib's does not do: the executable is resolved FIRST, so a
// command that does not exist is an error here and not an exec failure in a forked child
// (which vlib reports by printing in the child and exiting it — the parent never learns); and
// the child CLOSES every descriptor above stderr before exec — vlib's sockets are not
// close-on-exec, so an editor left open across Stop would otherwise keep a copy of the run's
// sockets, and a CANsub channel, which admits one client, would refuse the next Start until
// the editor exited (codex #307 r3). The child is reaped on its own thread: waitpid is where a
// zombie ends and the exit code becomes known, and a nonzero one reaches `report`.
fn launch_detached(argv []string, report fn (string)) ! {
	exe := os.find_abs_path_of_executable(argv[0]) or {
		return error('${argv[0]}: not found on PATH — set the command in Settings ▸ Preferences…')
	}
	mut cargs := []&char{cap: argv.len + 1}
	cargs << exe.str
	for a in argv[1..] {
		cargs << a.str
	}
	cargs << &char(unsafe { nil })
	pid := C.fork()
	if pid < 0 {
		return error('fork failed: ${os.posix_get_error_msg(C.errno)}')
	}
	if pid == 0 {
		// The child: only async-signal-safe calls between fork and exec — no allocation, no
		// locks (the GUI's other threads hold them at this instant, and the child has copies).
		// up to the process limit, not a fixed 1024: a descriptor above it would be inherited
		// (codex #307 r15). sysconf is async-signal-safe on glibc and musl.
		mut top := int(C.sysconf(C._SC_OPEN_MAX))
		if top < 1024 {
			top = 1024
		}
		for fd := 3; fd < top; fd++ {
			C.close(fd)
		}
		C.execv(exe.str, unsafe { &&char(cargs.data) })
		C._exit(127)
	}
	spawn reap(pid, argv[0], report)
}

fn reap(pid int, name string, report fn (string)) {
	mut status := 0
	if C.waitpid(pid, &status, 0) < 0 {
		return
	}
	// WIFSIGNALED / WEXITSTATUS without the macros: a signal sits in the low 7 bits, a normal
	// exit's code in bits 8..15. A crash is a failure to report too (codex #307 r15).
	sig := status & 0x7f
	if sig != 0 {
		report('${name} was killed by signal ${sig}')
		return
	}
	code := (status >> 8) & 0xff
	if code != 0 {
		report('${name} exited with ${code}')
	}
}

// replace_file moves `tmp` over `dst` in one step: rename(2) replaces atomically here.
fn replace_file(tmp string, dst string) ! {
	os.rename(tmp, dst)!
}

// process_alive reports whether `pid` is a running process: kill(pid, 0) sends nothing and
// answers whether it could have (EPERM is "alive, not ours").
fn process_alive(pid int) bool {
	if C.kill(pid, 0) == 0 {
		return true
	}
	return C.errno == 1 // EPERM
}

// claim_file links `src` as `dst` only if `dst` does not exist — link(2) fails with EEXIST,
// atomically — and drops the source name; the exclusive step lock ownership is published by
// (settings.v).
fn claim_file(src string, dst string) bool {
	if C.link(&char(src.str), &char(dst.str)) != 0 {
		return false
	}
	os.rm(src) or {}
	return true
}

// process_token is what tells one incarnation of a pid from the next: the process's start
// time in clock ticks since boot (field 22 of /proc/<pid>/stat), or '' where /proc is not
// there (which makes the pid the whole identity, as before).
fn process_token(pid int) string {
	stat := os.read_file('/proc/${pid}/stat') or { return '' }
	// the command name in field 2 is parenthesised and may hold spaces: split after its close
	rest := stat.all_after_last(') ')
	fields := rest.split(' ')
	// state is field 3, so starttime (field 22) is index 19 here
	if fields.len < 20 {
		return ''
	}
	return fields[19]
}

// wsl_windows_path is the Windows spelling of a Linux path under WSL (`\\wsl.localhost\...` or
// `C:\...` for /mnt/c), through wslpath; none elsewhere, or when wslpath cannot say.
fn wsl_windows_path(p string) ?string {
	if !is_wsl() {
		return none
	}
	win := os.execute('wslpath -w ' + os.quoted_path(p))
	if win.exit_code != 0 {
		return none
	}
	return win.output.trim_space()
}
