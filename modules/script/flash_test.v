module script

import os
import isotp
import flash
import transport
import crypto.ed25519 as ed

// A fake blobly bootloader on the in-process bus, strict where a real one is: 0x29 verifies the
// proof against the dev tester key, erase is refused until it has, and the check routine answers
// from the CRC the image header states over the bytes it was sent.
struct FakeBoot {
mut:
	ch      isotp.Channel
	authed  bool
	erases  int
	blocks  int
	checked int // 0x31 FF01 requests answered
	got     []u8
	resets  int
}

const challenge = []u8{len: 32, init: u8(0xA0 + index)}

fn boot_rd32(b []u8, off int) u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

fn fake_boot(mut b FakeBoot, stop chan bool) {
	public := ed.new_key_from_seed(flash.tester_seed('') or { panic(err) }).public_key()
	for {
		select {
			_ := <-stop {
				b.ch.close()
				return
			}
			else {}
		}
		req := b.ch.recv(200) or { continue }
		match req[0] {
			0x10 {
				b.ch.send([u8(0x50), req[1], 0x00, 0x32, 0x01, 0xF4]) or {}
			}
			0x29 {
				if req[1] == 0x01 {
					mut r := [u8(0x69), 0x01]
					r << challenge
					b.ch.send(r) or {}
				} else {
					ok := req.len == 2 + 64 && (ed.verify(public, challenge, req[2..]) or { false })
					b.authed = ok
					b.ch.send(if ok { [u8(0x69), 0x02] } else { [u8(0x7F), 0x29, 0x35] }) or {}
				}
			}
			0x31 {
				if !b.authed {
					b.ch.send([u8(0x7F), 0x31, 0x33]) or {}
					continue
				}
				mut result := u8(0)
				if req[3] == 0x00 {
					b.erases++
				} else {
					b.checked++
					// the header states the body length and its CRC
					n := int(boot_rd32(b.got, 8))
					if b.got.len < 64 + n || flash.crc32(b.got[64..64 + n]) != boot_rd32(b.got, 12) {
						result = 1
					}
				}
				b.ch.send([u8(0x71), 0x01, req[2], req[3], result]) or {}
			}
			0x34 {
				b.got = []u8{} // a download starts the slot over
				b.ch.send([u8(0x74), 0x20, 0x00, 0x42]) or {} // 64-byte blocks
			}
			0x36 {
				b.blocks++
				b.got << req[2..]
				b.ch.send([u8(0x76), req[1]]) or {}
			}
			0x37 {
				b.ch.send([u8(0x77)]) or {}
			}
			0x11 {
				b.resets++
				b.ch.send([u8(0x51), req[1]]) or {}
			}
			else {
				b.ch.send([u8(0x7F), req[0], 0x11]) or {}
			}
		}
	}
}

struct Bench {
mut:
	boot  &FakeBoot
	stop  chan bool
	t     thread
	env   &Env
	lines []string
	dir   string
}

// bench starts a fake bootloader on `wire` (0x7B0 in, 0x7B8 out) and a script env with one
// channel BOOT on it; the env's lines are kept.
fn bench(wire string) &Bench {
	mut boot := &FakeBoot{
		ch: isotp.open_software(wire, 0x7B8, 0x7B0, false) or { panic(err) }
	}
	stop := chan bool{cap: 1}
	t := spawn fake_boot(mut boot, stop)
	mut env := new_env([ChanInfo{
		name:  'BOOT'
		iface: wire
	}]) or { panic(err) }
	dir := os.join_path(os.temp_dir(), 'blobly_flash_${os.getpid()}_${wire.all_after(':')}')
	os.mkdir_all(dir) or { panic(err) }
	mut b := &Bench{
		boot: boot
		stop: stop
		t:    t
		env:  env
		dir:  dir
	}
	env.on_output = fn [mut b] (s string) {
		b.lines << s
	}
	return b
}

// done stops the boot (its record is read only after its thread has ended) and the env.
fn (mut b Bench) done() {
	b.stop <- true
	b.t.wait()
	b.env.close()
	os.rmdir_all(b.dir) or {}
}

// run writes `src` as a script in the bench directory and runs it as a file, so paths in it
// resolve against that directory.
fn (mut b Bench) run(src string) {
	path := os.join_path(b.dir, 'flash_suite.lua')
	os.write_file(path, src) or { panic(err) }
	b.env.run_file(path) or { panic(err) }
}

fn test_a_script_flashes_an_image_named_relative_to_itself() {
	mut b := bench('inproc:LFLASH1')
	defer {
		b.done()
	}
	image := []u8{len: 8000, init: u8(index * 7)}
	os.write_bytes(os.join_path(b.dir, 'fw.bin'), image)!
	b.run('
		test("flash", function()
			local calls, last = 0, -1
			local r = flash.program("BOOT", { image = "fw.bin", sw_version = 3,
				progress = function(done, total)
					calls = calls + 1
					check.truthy(done > last and done <= total, "progress rises")
					last = done
					if done == total then log("progress done " .. done .. "/" .. total .. " in " .. calls) end
				end })
			check.equal(r.auth, "authenticated")
			check.equal(r.wrapped, false)
			check.equal(r.reset_acknowledged, true)
			check.equal(r.bytes, 8064)
			check.equal(r.blocks, last, "the last progress call is the last block")
			check.truthy(calls <= 101, "one call per whole percent, not per block: " .. calls)
		end)
	')
	assert b.env.failed() == 0, b.lines.str()
	assert b.env.passed() == 1
	mut want := flash.make_header(image, 3)
	want << image
	assert b.boot.got == want
	assert b.boot.blocks == (want.len + 63) / 64
	assert b.boot.blocks > 101, 'the image must outrun a call per block'
	assert b.boot.resets == 1
	assert b.lines.any(it.starts_with('progress done ${b.boot.blocks}/${b.boot.blocks}'))
	// a callback replaces the transfer lines; the milestones are still said
	assert !b.lines.any(it.starts_with('flash: transfer ') && it.contains('blocks ('))
	assert b.lines.any(it == 'flash: image verified + marked valid')
}

fn test_without_a_callback_progress_is_a_line_per_tenth() {
	mut b := bench('inproc:LFLASH2')
	defer {
		b.done()
	}
	os.write_bytes(os.join_path(b.dir, 'fw.bin'), []u8{len: 6000})!
	b.run('
		test("flash", function() flash.program("BOOT", { image = "fw.bin" }) end)
	')
	assert b.env.failed() == 0, b.lines.str()
	n := b.lines.filter(it.starts_with('flash: transfer ') && it.contains('blocks (')).len
	assert n >= 10 && n <= 11, b.lines.str()
	assert b.lines.any(it == 'flash: transfer ${b.boot.blocks}/${b.boot.blocks} blocks (100%)')
}

fn test_a_wrong_key_is_refused_by_0x29_and_nothing_is_erased() {
	mut b := bench('inproc:LFLASH3')
	defer {
		b.done()
	}
	os.write_bytes(os.join_path(b.dir, 'fw.bin'), []u8{len: 100})!
	os.write_file(os.join_path(b.dir, 'other.seed'), '11'.repeat(32) + '\n')!
	b.run('
		test("seed", function()
			check.nrc(0x35, function() flash.program("BOOT", { image = "fw.bin", seed = string.rep("11", 32) }) end)
		end)
		test("seed_file", function()
			local ok, err = pcall(flash.program, "BOOT", { image = "fw.bin", seed_file = "other.seed", quiet = true })
			check.truthy(not ok and string.find(err, "send proof: NRC 0x35", 1, true), tostring(err))
		end)
		test("a malformed seed is an error, not the dev key", function()
			local ok, err = pcall(flash.program, "BOOT", { image = "fw.bin", seed = "0x1234" })
			check.truthy(not ok and string.find(err, "seed must be 64 hex", 1, true), tostring(err))
		end)
	')
	assert b.env.failed() == 0, b.lines.str()
	assert b.env.passed() == 3
	assert b.boot.erases == 0
	assert b.boot.blocks == 0
}

fn test_an_image_failing_the_check_routine_raises_and_is_not_reset() {
	mut b := bench('inproc:LFLASH4')
	defer {
		b.done()
	}
	body := []u8{len: 500, init: u8(index)}
	mut img := flash.make_header(body, 1)
	img[12] ^= 0xFF // the CRC the header states no longer matches the body
	img << body
	os.write_bytes(os.join_path(b.dir, 'bad.img'), img)!
	b.run('
		test("check", function()
			local ok, err = pcall(flash.program, "BOOT", { image = "bad.img" })
			check.truthy(not ok and string.find(err, "image check FAILED", 1, true), tostring(err))
		end)
	')
	assert b.env.failed() == 0, b.lines.str()
	assert b.boot.erases == 1
	assert b.boot.got == img, 'a wrapped image is transferred as it is'
	assert b.boot.checked == 1
	assert b.boot.resets == 0
}

// On a channel the project declares CAN-FD, a flash goes out in FD frames carrying classic-sized
// ISO-TP — the format the wire states, as uds.open's frames are — and over the connection a
// handoff was made on.
fn test_a_flash_on_a_canfd_wire_is_framed_fd_over_a_handed_off_connection() {
	wire := 'inproc:LFLASHFD'
	transport.set_wire_framing(wire, transport.Framing{ fd: true })
	defer {
		transport.set_wire_framing(wire, transport.Framing{})
	}
	mut tap := transport.open(wire)!
	mut b := bench(wire)
	defer {
		b.done()
		tap.close()
	}
	os.write_bytes(os.join_path(b.dir, 'fw.bin'), []u8{len: 300})!
	b.run('
		test("fd", function()
			local d = uds.open("BOOT", { tx = 0x7B0, rx = 0x7B8 })
			d:session(0x02)
			local r = flash.program(d, { image = "fw.bin", quiet = true })
			check.equal(r.auth, "authenticated")
		end)
	')
	assert b.env.failed() == 0, b.lines.str()
	assert b.lines.len == 1, 'quiet: only the verdict line, got ${b.lines}'
	mut tester, mut boot := 0, 0
	for {
		f := tap.recv(0) or { break }
		assert f.fd, 'a classic frame on an FD wire: ${f}'
		assert f.data.len <= 8, 'ISO-TP stays classic-sized'
		if f.id == 0x7B0 {
			tester++
		} else if f.id == 0x7B8 {
			boot++
		}
	}
	assert tester > 10 && boot > 10
}

fn test_a_raising_progress_callback_stops_the_transfer_before_the_check() {
	mut b := bench('inproc:LFLASH6')
	defer {
		b.done()
	}
	os.write_bytes(os.join_path(b.dir, 'fw.bin'), []u8{len: 3000})!
	b.run('
		test("abort", function()
			local ok, err = pcall(flash.program, "BOOT", { image = "fw.bin", progress = function(done, total)
				if done == 5 then error("wrong ECU") end
			end })
			check.truthy(not ok and string.find(err, "transfer stopped after block 5", 1, true)
				and string.find(err, "progress callback", 1, true) and string.find(err, "wrong ECU", 1, true), tostring(err))
		end)
		test("again, on the same connection", function()
			local r = flash.program("BOOT", { image = "fw.bin", quiet = true })
			check.equal(r.reset_acknowledged, true)
		end)
	')
	assert b.env.failed() == 0, b.lines.str()
	assert b.env.passed() == 2
	assert b.env.conns.len == 1, 'one connection for two flashes on one channel and id pair'
	assert b.boot.erases == 2
	assert b.boot.checked == 1, 'the stopped transfer was never checked'
}

fn test_bad_arguments_are_named() {
	mut b := bench('inproc:LFLASH5')
	defer {
		b.done()
	}
	b.run('
		local function refused(want, fn)
			local ok, err = pcall(fn)
			check.truthy(not ok and string.find(err, want, 1, true), "want " .. want .. ", got " .. tostring(err))
		end
		test("args", function()
			refused("opts.image must be", function() flash.program("BOOT", {}) end)
			refused("failed to open file", function() flash.program("BOOT", { image = "missing.bin" }) end)
			refused("unknown channel", function() flash.program("NOPE", { image = "x" }) end)
			refused("drop tx/rx", function() flash.program(uds.open("BOOT"), { image = "x", tx = 1 }) end)
			refused("seed and seed_file", function() flash.program("BOOT", { image = "flash_suite.lua", seed = "a", seed_file = "b" }) end)
			refused("base = -1", function() flash.program("BOOT", { image = "flash_suite.lua", base = -1 }) end)
			refused("tx is not an integer", function() flash.program("BOOT", { image = "flash_suite.lua", tx = true }) end)
			refused("rx is not an integer", function() flash.program("BOOT", { image = "flash_suite.lua", rx = {} }) end)
			refused("tx is not an integer", function() uds.open("BOOT", { tx = 1.5 }) end)
		end)
	')
	assert b.env.failed() == 0, b.lines.str()
	assert b.boot.erases == 0
}
