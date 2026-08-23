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
	mut quiet := open('inproc:lo_silent')!
	defer { quiet.close() }
	mut peer := open('inproc:lo_silent')!
	defer { peer.close() }

	set_listen_only('inproc:lo_silent', true)
	if _ := quiet.send(CanFrame{ id: 0x200, data: [u8(2)] }) {
		assert false, 'a listen-only wire transmitted'
	}
	// SILENCE IS A PROPERTY OF THE WIRE, not of the handle that was marked: the peer is on the
	// same bus and is refused too, which is the whole point -- one transceiver, one mode.
	if _ := peer.send(CanFrame{ id: 0x201, data: [u8(3)] }) {
		assert false, 'a second handle on a silenced wire transmitted'
	}
	// ... and it is still a monitor throughout. The flag stops us talking, not listening.
	clear_listen_only()
	peer.send(CanFrame{ id: 0x202, data: [u8(4)] })!
	set_listen_only('inproc:lo_silent', true)
	got := quiet.recv(200)!
	assert got.id == 0x202
	clear_listen_only()
}

// The mark travels with the WIRE, not with the spelling that opened it: canonical_iface
// collapses the addresses that reach one hub, so a second emitter naming it the other way does
// not quietly get a bus that transmits. (Trailing whitespace is NOT one of those spellings --
// see test_trailing_space_is_a_different_hub.)
fn test_mark_is_keyed_on_the_wire_not_the_spelling() {
	clear_listen_only()
	set_listen_only('inproc', true)
	assert is_listen_only('inproc:CAN'), 'the default hub name did not resolve to the same wire'
	assert is_listen_only('inproc:')
	assert !is_listen_only('inproc:other')
	clear_listen_only()
	assert !is_listen_only('inproc')
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

// The mark is consulted PER SEND, so a handle that is already open follows it in both
// directions. This is the guarantee that makes a policy change reach a Lua script holding a bus
// across Stop, and a tap opened before its row was ticked (codex #164 r1).
fn test_an_open_handle_follows_the_mark_both_ways() {
	clear_listen_only()
	mut b := open('inproc:lo_toggle')!
	defer { b.close() }
	mut ear := open('inproc:lo_toggle')!
	defer { ear.close() }
	b.send(CanFrame{ id: 0x400, data: [u8(5)] })! // opened unmarked: transmits
	assert ear.recv(200)!.id == 0x400

	set_listen_only('inproc:lo_toggle', true) // marked AFTER the open
	if _ := b.send(CanFrame{ id: 0x401, data: [u8(6)] }) {
		assert false, 'an already-open handle ignored a mark set after it was opened'
	}

	set_listen_only('inproc:lo_toggle', false) // and released, on the same handle
	b.send(CanFrame{ id: 0x402, data: [u8(7)] })!
	assert ear.recv(200)!.id == 0x402
	clear_listen_only()
}

// replace_listen_only swaps the set in ONE locked step. clear-then-set left a window in which a
// bus opened by another thread read an empty table and transmitted for its whole lifetime.
fn test_replace_swaps_the_whole_set_at_once() {
	clear_listen_only()
	set_listen_only('inproc:lo_old', true)
	replace_listen_only(['inproc:lo_new'])
	assert !is_listen_only('inproc:lo_old'), 'the old set survived a replace'
	assert is_listen_only('inproc:lo_new')
	replace_listen_only([])
	assert !is_listen_only('inproc:lo_new')
}

// `inproc:bench` and `inproc:bench ` are two hubs -- the dispatcher does not trim, and
// canonical_iface deliberately does not either. A key that trimmed would silence a bus nobody
// ticked.
fn test_trailing_space_is_a_different_hub() {
	clear_listen_only()
	set_listen_only('inproc:lo_space ', true)
	assert is_listen_only('inproc:lo_space ')
	assert !is_listen_only('inproc:lo_space'), 'a trimmed key merged two separate hubs'
	clear_listen_only()
}
