module flash

import isotp

// A fake blobly bootloader on the in-process bus, doing the two things a real one does that the
// flasher's old request loop could not take: it answers the erase with responsePending (0x78)
// before its result, and it lets a late copy of block 1's answer (a CAN retransmission) arrive
// while block 2's is awaited. It records what it was sent, so the test can check the image.
struct FakeBoot {
mut:
	ch       isotp.Channel
	auth_nrc u8 // the NRC 0x29 01 is refused with (a boot with no key baked)
	got      []u8
	blocks   int
}

fn fake_boot(mut b FakeBoot, stop chan bool) {
	for {
		select {
			_ := <-stop {
				b.ch.close()
				return
			}
			else {}
		}
		req := b.ch.recv(200) or { continue } // one deadline per PDU: room for a 66-byte block
		match req[0] {
			0x10 {
				b.ch.send([u8(0x50), req[1], 0x00, 0x32, 0x01, 0xF4]) or {}
			}
			0x29 {
				b.ch.send([u8(0x7F), 0x29, b.auth_nrc]) or {}
			}
			0x31 {
				if req[3] == 0x00 { // erase: pending first
					b.ch.send([u8(0x7F), 0x31, 0x78]) or {}
				}
				b.ch.send([u8(0x71), 0x01, req[2], req[3], 0x00]) or {}
			}
			0x34 {
				b.ch.send([u8(0x74), 0x20, 0x00, 0x42]) or {} // 64-byte blocks
			}
			0x36 {
				b.blocks++
				b.got << req[2..]
				if req[1] == 2 {
					b.ch.send([u8(0x76), 0x01]) or {} // block 1's answer, late
				}
				b.ch.send([u8(0x76), req[1]]) or {}
			}
			0x37 {
				b.ch.send([u8(0x77)]) or {}
			}
			0x11 {
				b.ch.send([u8(0x51), req[1]]) or {}
			}
			else {
				b.ch.send([u8(0x7F), req[0], 0x11]) or {}
			}
		}
	}
}

struct Notes {
mut:
	lines []string
}

fn (mut n Notes) note(s string) {
	n.lines << s
}

fn (mut n Notes) block(done int, total int) ! {}

fn test_a_pending_erase_and_a_late_block_answer_do_not_derail_the_session() {
	mut boot := &FakeBoot{
		ch:       isotp.open_software('inproc:FLASH', 0x7E8, 0x7E0, false) or { panic(err) }
		auth_nrc: 0x11
	}
	stop := chan bool{cap: 1}
	t := spawn fake_boot(mut boot, stop)
	mut ch := isotp.Channel(isotp.open_software('inproc:FLASH', 0x7E0, 0x7E8, false) or {
		panic(err)
	})
	image := []u8{len: 200, init: u8(index)}
	mut notes := Notes{}
	program(mut ch, image, Opts{ auth_seed: []u8{len: 32} }, mut notes) or {
		stop <- true
		t.wait()
		ch.close()
		assert false, 'flash failed: ${err}'
		return
	}
	stop <- true
	t.wait() // the boot's record is read only after its thread has ended
	ch.close()
	assert notes.lines.any(it.contains('0x29 not required'))
	assert notes.lines.any(it.contains('image verified'))
	assert notes.lines.last() == 'ECU reset — done'
	// header + image, every byte once, in order: no block was answered by another's answer
	mut want := make_header(image, 1)
	want << image
	assert boot.got == want
	assert boot.blocks == (want.len + 63) / 64
}

fn test_a_secured_boot_refusing_the_challenge_stops_the_flash() {
	mut boot := &FakeBoot{
		ch:       isotp.open_software('inproc:FLASH2', 0x7E8, 0x7E0, false) or { panic(err) }
		auth_nrc: 0x31
	}
	stop := chan bool{cap: 1}
	t := spawn fake_boot(mut boot, stop)
	mut ch := isotp.Channel(isotp.open_software('inproc:FLASH2', 0x7E0, 0x7E8, false) or {
		panic(err)
	})
	mut notes := Notes{}
	mut msg := ''
	program(mut ch, []u8{len: 10}, Opts{ auth_seed: []u8{len: 32} }, mut notes) or {
		msg = err.msg()
	}
	stop <- true
	t.wait()
	ch.close()
	assert msg == 'request challenge: NRC 0x31', 'a refused challenge was flashed through'
	assert boot.blocks == 0
}
