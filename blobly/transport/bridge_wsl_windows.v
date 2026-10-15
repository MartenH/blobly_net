module transport

import os

#include <windows.h>
#include <shellapi.h>
#flag windows -lshell32

fn C.ShellExecuteW(hwnd voidptr, op &u16, file &u16, params &u16, dir &u16, show int) voidptr

// The registry, through the W entry points vlib already declares (builtin/cfns.c.v) plus the one
// it does not.
fn C.RegEnumKeyExW(hkey voidptr, idx u32, name &u16, len &u32, r voidptr, cls &u16, clen &u32, ft voidptr) int

// wsl_distros lists the WSL distributions installed for this user, from the registry
// (HKCU\...\Lxss\<guid>\DistributionName) rather than `wsl.exe -l`, which is a console process a
// GUI would flash a window for. Empty where WSL is not installed.
pub fn wsl_distros() []string {
	mut lxss := unsafe { nil }
	if C.RegOpenKeyExW(voidptr(C.HKEY_CURRENT_USER),
		'Software\\Microsoft\\Windows\\CurrentVersion\\Lxss'.to_wide(), 0, u32(C.KEY_READ), &lxss) != 0 {
		return []
	}
	defer {
		C.RegCloseKey(lxss)
	}
	mut out := []string{}
	for i := u32(0); i < 64; i++ {
		mut key := [256]u16{}
		mut klen := u32(255)
		if C.RegEnumKeyExW(lxss, i, &key[0], &klen, unsafe { nil }, unsafe { nil },
			unsafe { nil }, unsafe { nil }) != 0 {
			break
		}
		mut sub := unsafe { nil }
		if C.RegOpenKeyExW(lxss, &key[0], 0, u32(C.KEY_READ), &sub) != 0 {
			continue
		}
		mut data := [512]u16{}
		mut dlen := u32(1022) // bytes
		mut typ := u32(0)
		if C.RegQueryValueExW(sub, 'DistributionName'.to_wide(), unsafe { nil }, &typ, &u8(&data[0]), &dlen) == 0
			&& typ == 1 {
			distro := unsafe { string_from_wide(&data[0]) }
			if distro != '' {
				out << distro
			}
		}
		C.RegCloseKey(sub)
	}
	out.sort()
	return out
}

// bridge_launch_wsl starts `canbridge` in a WSL distribution, as root (so it can create the vcan
// interfaces) and with no console window, telling it where to dial and the token to present.
// The bridge's own `canbridge` is the one shipped beside this executable, else one on the
// distribution's PATH. Whether it then dials in is the caller's to wait for: a bridge that cannot
// start says why in its hello.
fn bridge_launch_wsl(distro string, ep BridgeEndpoint) ! {
	dir := os.dir(os.executable())
	mut args := ['-d', distro, '-u', 'root']
	if os.is_file(os.join_path(dir, 'canbridge')) {
		args << ['--cd', dir, '--', './canbridge']
	} else {
		args << ['--', 'canbridge']
	}
	args << bridge_launch_args(distro, ep)
	params := args.map(win_quote(it)).join(' ')
	// SW_HIDE = 0. A return above 32 is a launch; anything else is why not.
	r := int(usize(C.ShellExecuteW(unsafe { nil }, 'open'.to_wide(), 'wsl.exe'.to_wide(),
		params.to_wide(), unsafe { nil }, 0)))
	if r <= 32 {
		return error('wsl.exe did not start (ShellExecute ${r}) — is WSL installed?')
	}
}

// win_quote spells one argument the way CommandLineToArgv reads it back.
fn win_quote(a string) string {
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
