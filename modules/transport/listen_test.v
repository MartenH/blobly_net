module transport

// listen-only is enforced in open(), so these tests open real buses -- inproc ones, which need
// no driver -- and assert what comes back refuses to transmit while still receiving. Asserting
// on the table alone would test the bookkeeping and not the promise.

fn test_unmarked_wire_transmits() {
	clear_listen_only()
	mut a := open('inproc:lo_plain')!
	defer { a.close() }
	mut b := open('inproc:lo_plain')!
	defer { b.close() }
	a.send(CanFrame{ id: 0x101, data: [u8(1)] })!
	got := b.recv(200)!
	assert got.id == 0x101
}

fn test_marked_wire_refuses_to_send_but_still_receives() {
	clear_listen_only()
	// the LISTENER is the marked one; its peer is not, so there is something to hear
	set_listen_only('inproc:lo_silent', true)
	mut quiet := open('inproc:lo_silent')!
	defer { quiet.close() }
	clear_listen_only()
	mut talker := open('inproc:lo_silent')!
	defer { talker.close() }

	set_listen_only('inproc:lo_silent', true)
	if _ := quiet.send(CanFrame{ id: 0x200, data: [u8(2)] }) {
		assert false, 'a listen-only wire transmitted'
	}
	// ... and it is still a monitor: the flag stops us talking, not listening
	talker.send(CanFrame{ id: 0x201, data: [u8(3)] })!
	got := quiet.recv(200)!
	assert got.id == 0x201
	clear_listen_only()
}

// The mark travels with the WIRE, not with the spelling that opened it, or a second emitter
// naming the same bus differently would quietly get a bus that transmits.
fn test_mark_is_keyed_on_the_wire_not_the_spelling() {
	clear_listen_only()
	set_listen_only('inproc:lo_alias', true)
	assert is_listen_only('  inproc:lo_alias  ') // trimmed
	assert !is_listen_only('inproc:lo_other')
	clear_listen_only()
	assert !is_listen_only('inproc:lo_alias')
}

// `@` is a bitrate suffix on a vendor address and part of the NAME everywhere else. Cutting it
// off an inproc bus would mark a different hub than the operator ticked.
fn test_at_sign_is_a_bitrate_only_for_vendor_addresses() {
	clear_listen_only()
	set_listen_only('inproc:bench@A', true)
	assert is_listen_only('inproc:bench@A')
	assert !is_listen_only('inproc:bench'), 'the @ was treated as a bitrate on a bus name'
	assert !is_listen_only('inproc:bench@B')
	clear_listen_only()
}

// A wire marked by one project must not silence the next one that reuses the interface.
fn test_clear_releases_every_wire() {
	clear_listen_only()
	set_listen_only('inproc:lo_a', true)
	set_listen_only('inproc:lo_b', true)
	clear_listen_only()
	assert !is_listen_only('inproc:lo_a')
	assert !is_listen_only('inproc:lo_b')
	mut a := open('inproc:lo_a')!
	defer { a.close() }
	mut b := open('inproc:lo_a')!
	defer { b.close() }
	a.send(CanFrame{ id: 0x300, data: [u8(4)] })! // transmits again
	got := b.recv(200)!
	assert got.id == 0x300
}

// Unmarking is not the same as never marking: a row unticked while stopped must transmit on the
// next Start, and only a bus opened AFTER the change can reflect it.
fn test_unmark_restores_transmission_on_the_next_open() {
	clear_listen_only()
	set_listen_only('inproc:lo_toggle', true)
	mut quiet := open('inproc:lo_toggle')!
	if _ := quiet.send(CanFrame{ id: 0x400, data: [u8(5)] }) {
		assert false, 'a listen-only wire transmitted'
	}
	quiet.close()
	set_listen_only('inproc:lo_toggle', false)
	mut loud := open('inproc:lo_toggle')!
	defer { loud.close() }
	mut ear := open('inproc:lo_toggle')!
	defer { ear.close() }
	loud.send(CanFrame{ id: 0x401, data: [u8(6)] })!
	got := ear.recv(200)!
	assert got.id == 0x401
	clear_listen_only()
}
