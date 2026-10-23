// flash.v — bb.h's flash calls: blobly/flash's download session on a UDS handle, the session
// cmd/flash, the GUI's Flash panel and the Lua flash.program run, its milestones and progress
// handed to the host's callbacks; and a simulated bootloader to rehearse it against.
module main

import sync.stdatomic
import blobly.flash
import blobly.isotp
import blobly.udsconn

const bb_err_flash = i32(C.BB_ERR_FLASH)

type FlashNote = fn (voidptr, &char)

type FlashProgress = fn (voidptr, i32, i32)

// AbiSink is where a host's flash reports: milestones to `note`, transfer progress to `progress`
// per whole percent (flash.Percent) or, without it, a note per tenth (flash.Tenths); quiet, no
// notes. A cancelled flash stops at the next block, before the check.
struct AbiSink {
mut:
	note     voidptr
	progress voidptr
	ctx      voidptr
	quiet    bool
	cancel   &i64
	tenths   flash.Tenths
	percent  flash.Percent
}

fn (mut s AbiSink) note(msg string) {
	if !s.quiet && !isnil(s.note) {
		f := unsafe { FlashNote(s.note) }
		f(s.ctx, &char(msg.str))
	}
}

fn (mut s AbiSink) block(done int, total int) ! {
	if stdatomic.load_i64(s.cancel) != 0 {
		return error('cancelled (bb_flash_cancel)')
	}
	if !isnil(s.progress) {
		if _ := s.percent.due(done, total) {
			f := unsafe { FlashProgress(s.progress) }
			f(s.ctx, i32(done), i32(total))
			// a host that cancels from its callback stops the transfer here
			if stdatomic.load_i64(s.cancel) != 0 {
				return error('cancelled (bb_flash_cancel)')
			}
		}
		return
	}
	if pct := s.tenths.due(done, total) {
		s.note('transfer ${done}/${total} blocks (${pct}%)')
	}
}

// opt_str is a host's optional string: none for NULL.
fn opt_str(p &char) ?string {
	if isnil(p) {
		return none
	}
	return unsafe { cstring_to_vstring(p) }
}

@[export: 'bb_flash_defaults']
pub fn bb_flash_defaults(out &C.bb_flash_opts) i32 {
	if isnil(out) {
		return fail(bb_err, 'flash defaults: nowhere to put them')
	}
	d := flash.Opts{}
	unsafe {
		vmemset(out, 0, int(sizeof(C.bb_flash_opts)))
		out.base = d.base
		out.sw_version = d.sw_version
		out.auth = 1
	}
	return ok()
}

@[export: 'bb_flash_open']
pub fn bb_flash_open(r i32, tx &i64, rx &i64, out &C.bb_uds_target) i32 {
	return uds_open(r, tx, rx, out, udsconn.Ask{
		what: 'flash'
		dtx:  flash.tester_tx
		drx:  flash.boot_tx
	})
}

@[export: 'bb_flash_program']
pub fn bb_flash_program(u i32, image &u8, n i32, opts &C.bb_flash_opts, out &C.bb_flash_report) i32 {
	if isnil(opts) || isnil(out) {
		return fail(bb_err, 'flash: no options, or nowhere to put the report')
	}
	img := bytes_in('flash: image', image, n) or { return fail(bb_err, err.msg()) }
	if img.len == 0 {
		return fail(bb_err, 'flash: the image is empty')
	}
	o := unsafe { *opts }
	seed := flash.auth_seed(o.auth != 0, opt_str(o.seed), opt_str(o.seed_file)) or {
		return fail(bb_err, 'flash: ${err}')
	}
	return exchange(u, fn [img, o, seed, out] (mut hd UdsHandle) !i32 {
		hd.fmu.lock()
		hd.flashing = true
		hd.fmu.unlock()
		defer {
			hd.fmu.lock()
			hd.flashing = false
			stdatomic.store_i64(&hd.cancel, 0)
			hd.fmu.unlock()
		}
		cancel := &hd.cancel
		cancelled := fn [cancel] (err IError) IError {
			if stdatomic.load_i64(cancel) != 0 {
				return flash.Failed{
					text: 'flash cancelled (bb_flash_cancel): ${err}'
				}
			}
			return err
		}
		hd.cli() or { return cancelled(err) }
		mut sink := AbiSink{
			note:     o.note
			progress: o.progress
			ctx:      o.ctx
			quiet:    o.quiet != 0
			cancel:   &hd.cancel
		}
		mut ch := hd.conn.ch
		sink.note('${hd.row_name} 0x${ch.tx_id:X}/0x${ch.rx_id:X} @0x${o.base.hex()}, sw_version ${o.sw_version}')
		rep := flash.program(mut ch, img, flash.Opts{
			base:       o.base
			sw_version: o.sw_version
			auth_seed:  seed
			stop:        hd.stop
			on_exchange: hd.conn.cli.on_exchange // the handle's last exchange is the session's
		}, mut sink) or { return cancelled(err) }
		unsafe {
			out.bytes = i32(rep.bytes)
			out.blocks = i32(rep.blocks)
			out.wrapped = u8(rep.wrapped)
			out.reset_acknowledged = u8(rep.reset_acknowledged)
			out.auth = match rep.auth {
				'authenticated' { i32(C.BB_FLASH_AUTHENTICATED) }
				'not required' { i32(C.BB_FLASH_NOT_REQUIRED) }
				else { i32(C.BB_FLASH_SKIPPED) }
			}
		}
		return ok()
	})
}

// bb_flash_cancel: the flash in progress on handle u stops — its waits end within a stop poll
// (20 ms), a transfer before its next block — and bb_flash_program answers BB_ERR_FLASH. Nothing
// when none is in progress. From any thread.
@[export: 'bb_flash_cancel']
pub fn bb_flash_cancel(u i32) i32 {
	mut hd := uds_enter(u) or { return fail(bb_err_handle, 'no open UDS handle ${u}') }
	defer {
		stdatomic.add_i64(&hd.users, -1)
	}
	hd.fmu.lock()
	if hd.flashing {
		stdatomic.store_i64(&hd.cancel, 1)
	}
	hd.fmu.unlock()
	return ok()
}

__global (
	bb_boots     map[int]&flash.BootSim
	bb_boot_next int
)

@[export: 'bb_boot_sim']
pub fn bb_boot_sim(r i32, tx &i64, rx &i64) i32 {
	bb_mu.lock()
	live := bb_dbs_live
	rows := bb_run_rows
	bb_mu.unlock()
	if !live {
		return fail(bb_err_state, 'boot sim: not started — it serves a row of the run')
	}
	if r < 0 || int(r) >= rows.len {
		return fail(bb_err, 'boot sim: no channel ${r}')
	}
	ch := rows[int(r)]
	ask := udsconn.Ask{
		what:   'boot sim'
		has_tx: !isnil(tx)
		tx:     if isnil(tx) { i64(0) } else { unsafe { *tx } }
		has_rx: !isnil(rx)
		rx:     if isnil(rx) { i64(0) } else { unsafe { *rx } }
		dtx:    flash.tester_tx
		drx:    flash.boot_tx
	}
	t := udsconn.resolve(ask, ch.name, udsconn.carrier_of(ch)) or { return fail(bb_err, err.msg()) }
	if t.doip {
		return fail(bb_err, 'boot sim("${ch.name}"): a simulated bootloader answers on a CAN row')
	}
	// it answers on the tester's response id and hears its request id
	c := isotp.open_software(ch.iface_with_bitrate(), t.rx, t.tx, t.ext) or {
		return fail(bb_err, 'boot sim("${ch.name}"): ${err}')
	}
	b := flash.start_boot_sim(c)
	bb_mu.lock()
	id := bb_boot_next
	bb_boot_next++
	bb_boots[id] = b
	bb_mu.unlock()
	ok()
	return i32(id)
}

// boot_sims_stop stops every simulated bootloader (bb_stop), so none answers into the next run; each
// stays in the table until bb_boot_sim_stop reads its report.
fn boot_sims_stop() {
	bb_mu.lock()
	mut sims := bb_boots.values()
	bb_mu.unlock()
	for mut s in sims {
		s.stop()
	}
}

@[export: 'bb_boot_sim_stop']
pub fn bb_boot_sim_stop(b i32, out &C.bb_boot_report) i32 {
	bb_mu.lock()
	mut sim := bb_boots[int(b)] or {
		bb_mu.unlock()
		return fail(bb_err_handle, 'no simulated bootloader ${b}')
	}
	bb_boots.delete(int(b))
	bb_mu.unlock()
	rep := sim.stop()
	if !isnil(out) {
		unsafe {
			out.authenticated = u8(rep.authenticated)
			out.verified = u8(rep.verified)
			out.erases = i32(rep.erases)
			out.blocks = i32(rep.blocks)
			out.bytes = i32(rep.image.len)
			out.checks = i32(rep.checks)
			out.resets = i32(rep.resets)
		}
	}
	return ok()
}
