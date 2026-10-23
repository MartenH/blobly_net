module script

// flash.program — a blobly_emb bootloader's download session from a script. The session itself is
// blobly/flash, the same code cmd/flash and the GUI's Flash panel run; this file is the Lua face
// of it: where the image and the seed come from, and where progress goes.
import os
import blobly.lua
import blobly.flash

// LuaFlashSink is where a script's flash reports: milestones as `flash: …` lines through the
// host's sink, transfer progress either as a line per tenth of the image (as cmd/flash prints)
// or, when the script gave a callback, as a call per whole percent — at most 101 calls however
// many blocks the image takes, so a callback that prints does not flood. A callback that raises
// stops the transfer before the check, so the image is never marked valid.
struct LuaFlashSink {
mut:
	env      &Env
	l        lua.State
	quiet    bool
	callback bool
	tenths   flash.Tenths
	percent  flash.Percent
}

fn (mut s LuaFlashSink) note(msg string) {
	if !s.quiet {
		s.env.emit('flash: ${msg}')
	}
}

fn (mut s LuaFlashSink) block(done int, total int) ! {
	if s.callback {
		if _ := s.percent.due(done, total) {
			s.l.call_global_ints('__flash_progress', [i64(done), i64(total)]) or {
				return error('progress callback: ${err}')
			}
		}
		return
	}
	if s.quiet {
		return
	}
	if pct := s.tenths.due(done, total) {
		s.env.emit('flash: transfer ${done}/${total} blocks (${pct}%)')
	}
}

// script_relative resolves a path a script names as `-- @project` is resolved (from_script). A
// script run from source text has no directory and resolves against the working directory.
fn (env &Env) script_relative(p string) string {
	if env.script_path == '' {
		return p
	}
	return from_script(env.script_path, p)
}

fn l_flash_open(l lua.State) i32 {
	// cmd/flash's default pair: a blobly_emb bootloader answers on 0x7B0/0x7B8
	return open_conn(l, 'flash.program', flash.tester_tx, flash.boot_tx, true)
}

// u32_arg reads an optional u32 argument: `dflt` when nil, an error when it is not one.
fn u32_arg(l lua.State, i int, what string, dflt u32) !u32 {
	if l.arg_is_nil(i) {
		return dflt
	}
	v := l.arg_int_exact(i) or { return error('${what} is not an integer') }
	if v < 0 || v > 0xFFFF_FFFF {
		return error('${what} = ${v} is not a 32-bit value')
	}
	return u32(v)
}

// l_flash_program(handle, image, base, sw_version, auth, seed, seed_file, progress, quiet) runs the
// session over the uds.open connection `handle` and returns what it did as a table; a failed step
// raises with the step named (`erase: NRC 0x22`, `image check FAILED …`).
fn l_flash_program(l lua.State) i32 {
	mut env := env_of(l)
	c := env.conn(int(l.arg_int(1))) or { return l.fail('flash.program: bad uds handle') }
	// copied out: the progress callback runs Lua, and a uds.open there grows env.conns under `c`
	mut ch := c.ch
	what := 'flash.program("${c.chan}")'
	path := l.arg_str(2)
	full := env.script_relative(path)
	image := os.read_bytes(full) or { return l.fail('${what}: image ${full}: ${err}') }
	if image.len == 0 {
		return l.fail('${what}: image ${full} is empty')
	}
	mut opts := flash.Opts{}
	opts.base = u32_arg(l, 3, 'base', opts.base) or { return l.fail('${what}: ${err}') }
	opts.sw_version = u32_arg(l, 4, 'sw_version', opts.sw_version) or {
		return l.fail('${what}: ${err}')
	}
	seed := if l.arg_is_nil(6) { ?string(none) } else { ?string(l.arg_str(6)) }
	seed_file := if l.arg_is_nil(7) { ?string(none) } else { ?string(env.script_relative(l.arg_str(7))) }
	opts.auth_seed = flash.auth_seed(l.arg_bool(5), seed, seed_file) or {
		return l.fail('${what}: ${err}')
	}
	mut sink := LuaFlashSink{
		env:      env
		l:        l
		callback: l.arg_bool(8)
		quiet:    l.arg_bool(9)
	}
	sink.note('${full} -> ${c.chan} 0x${ch.tx_id:X}/0x${ch.rx_id:X} @0x${opts.base.hex()}, sw_version ${opts.sw_version}')
	if env.deadline != 0 {
		opts.stop = fn [env] () bool {
			return env.expired()
		}
	}
	rep := flash.program(mut ch, image, opts, mut sink) or {
		if env.expired() {
			return timeout_at(l) // stopped by the run deadline
		}
		return l.fail('${what}: ${err}')
	}
	l.new_table()
	l.set_int('bytes', rep.bytes)
	l.set_int('blocks', rep.blocks)
	l.set_bool('wrapped', rep.wrapped)
	l.set_str('auth', rep.auth)
	l.set_bool('reset_acknowledged', rep.reset_acknowledged)
	return 1
}
