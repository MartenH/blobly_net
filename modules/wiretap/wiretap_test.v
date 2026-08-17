module wiretap

import transport

fn frame(id u32, data []u8) transport.CanFrame {
	return transport.CanFrame{
		id:   id
		data: data
	}
}

fn test_a_frame_we_sent_is_recognised_as_ours() {
	mut r := Ring{}
	f := frame(0x120, [u8(1), 2, 3])
	r.note(7, 'vcan0', f, 0, [0], '', false)
	c := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'our own frame came back and we did not recognise it'
		return
	}
	assert c.seq == 7
	// still held — a second monitor on this interface gets its own copy of the frame and would
	// otherwise see our own emission as foreign. Expiry retires it, silently, having been seen.
	assert r.outstanding() == 1
	assert r.expire(default_window_ms + 1) == []u64{}
	assert r.outstanding() == 0
}

// The reason the whole mechanism exists: a simulated ECU left running while the real one it
// stands in for is on the bench. Both send 0x120; today they are one indistinguishable stream.
fn test_a_second_identical_frame_is_the_other_transmitter() {
	mut r := Ring{}
	f := frame(0x120, [u8(1), 2, 3])
	r.note(1, 'vcan0', f, 0, [0], '', false)
	r.claim(0, 'vcan0', f, 1) or {
		assert false, 'ours was not claimed'
		return
	}
	// Nothing of ours is left, so this one belongs to somebody else — which is exactly the
	// duplicate transmitter we want on screen. Matching without consuming would swallow it.
	if _ := r.claim(0, 'vcan0', f, 2) {
		assert false, 'a second identical frame was attributed to us — the collision is hidden'
	}
}

fn test_claims_oldest_first() {
	mut r := Ring{}
	f := frame(0x120, [u8(9)])
	r.note(1, 'vcan0', f, 0, [0], '', false)
	r.note(2, 'vcan0', f, 5, [0], '', false)
	ca := r.claim(0, 'vcan0', f, 6) or {
		assert false, '${err}'
		return
	}
	cb := r.claim(0, 'vcan0', f, 7) or {
		assert false, '${err}'
		return
	}
	assert ca.seq == 1 && cb.seq == 2, 'frames leave in order, so their echoes must be claimed in order'
}

fn test_another_bus_is_not_our_echo() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [0], '', false)
	if _ := r.claim(0, 'vcan1', f, 1) {
		assert false, 'a frame on a DIFFERENT bus was attributed to what we sent on this one'
	}
}

fn test_a_different_payload_is_not_our_echo() {
	mut r := Ring{}
	r.note(1, 'vcan0', frame(0x120, [u8(1), 2, 3]), 0, [0], '', false)
	if _ := r.claim(0, 'vcan0', frame(0x120, [u8(1), 2, 4]), 1) {
		assert false, 'same id, different bytes — that is another sender, not our echo'
	}
}

// The width-exact invariant this repo has been bitten by before: an extended frame must never
// pass as a standard one sharing the low 11 bits.
fn test_extended_is_not_the_echo_of_standard() {
	mut r := Ring{}
	std := transport.CanFrame{
		id:   0x120
		data: [u8(1)]
	}
	ext := transport.CanFrame{
		id:       0x120
		extended: true
		data:     [u8(1)]
	}
	r.note(1, 'vcan0', std, 0, [0], '', false)
	if _ := r.claim(0, 'vcan0', ext, 1) {
		assert false, 'an extended frame masqueraded as our standard one'
	}
}

fn test_rtr_is_not_the_echo_of_a_data_frame() {
	mut r := Ring{}
	data := transport.CanFrame{
		id:   0x120
		data: []
	}
	rtr := transport.CanFrame{
		id:  0x120
		rtr: true
	}
	r.note(1, 'vcan0', data, 0, [0], '', false)
	if _ := r.claim(0, 'vcan0', rtr, 1) {
		assert false, 'a remote request was taken for the echo of a data frame'
	}
}

// A frame we sent that never reached the wire is the finding, not a gap: CAN needs an ACK from
// at least one other node, so a lone node's frames never make it at all.
fn test_an_echo_that_never_comes_is_reported_once() {
	mut r := Ring{}
	r.note(42, 'vcan0', frame(0x120, [u8(1)]), 0, [0], '', false)
	assert r.expire(500) == []u64{}, 'still inside the window — nothing to report yet'
	assert r.expire(default_window_ms + 1) == [u64(42)]
	assert r.expire(default_window_ms + 2) == []u64{}, 'a missed frame must not be reported twice'
	assert r.outstanding() == 0
}

fn test_an_expired_emission_cannot_be_claimed() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [0], '', false)
	if _ := r.claim(0, 'vcan0', f, default_window_ms + 1) {
		assert false, 'a frame arriving long after ours was attributed to us'
	}
}

// Two channel entries may watch one interface; each monitor gets its own copy of every frame.
fn test_each_monitor_accounts_for_the_frame_once() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(5, 'vcan0', f, 0, [0, 1], '', false)
	ca := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'monitor 0 did not recognise our frame'
		return
	}
	cb := r.claim(1, 'vcan0', f, 1) or {
		assert false, 'the SECOND monitor saw our own frame as foreign'
		return
	}
	assert ca.seq == 5 && cb.seq == 5
	// but a repeat at a monitor that already accounted for it is somebody else transmitting
	if _ := r.claim(0, 'vcan0', f, 2) {
		assert false, 'a duplicate transmitter was hidden by the per-monitor rule'
	}
}

// An emission already accounted for by one monitor must not be reported as missing just because
// it lingers for a second monitor that never came.
fn test_a_claimed_emission_is_not_reported_missing() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(9, 'vcan0', f, 0, [0], '', false)
	r.claim(0, 'vcan0', f, 1) or {
		assert false, '${err}'
		return
	}
	assert r.expire(default_window_ms + 1) == []u64{}
}

fn test_a_failed_send_is_forgotten_without_a_verdict() {
	mut r := Ring{}
	r.note(3, 'vcan0', frame(0x120, [u8(1)]), 0, [0], '', false)
	r.forget(3)
	assert r.expire(default_window_ms + 1) == []u64{}, 'a send that never left reported as missed'
	assert r.outstanding() == 0
}

fn test_eviction_reports_what_it_drops() {
	mut r := Ring{
		cap: 2
	}
	assert r.note(1, 'vcan0', frame(0x101, [u8(1)]), 0, [0], '', false) == []u64{}
	assert r.note(2, 'vcan0', frame(0x102, [u8(2)]), 0, [0], '', false) == []u64{}
	// the third pushes the first out: reported, never silently dropped — going quiet here would
	// go quiet in exactly the busy-bus case where a dead link matters
	assert r.note(3, 'vcan0', frame(0x103, [u8(3)]), 0, [0], '', false) == [u64(1)]
}

fn test_the_ring_is_bounded() {
	mut r := Ring{
		cap: 4
	}
	for i in 0 .. 10 {
		r.note(u64(i), 'vcan0', frame(u32(0x100 + i), [u8(i)]), 0, [0], '', false)
	}
	assert r.outstanding() == 4
	// the oldest were dropped, so they read as somebody else's rather than pinning memory
	if _ := r.claim(0, 'vcan0', frame(0x100, [u8(0)]), 1) {
		assert false, 'a dropped record still claimed a frame'
	}
	c := r.claim(0, 'vcan0', frame(0x109, [u8(9)]), 1) or {
		assert false, 'the newest record should still be there'
		return
	}
	assert c.seq == 9
}

// A row identity the trace has already discarded must still suppress its echo: the frame is
// ours whether or not a row is left to mark.
fn test_a_record_outlives_its_row() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [0], '', false)
	c := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'our own frame became foreign once its row was gone'
		return
	}
	assert c.seq == 1
}

// A monitor that opened AFTER the frame went out never saw it, so it must not be able to claim
// the record — otherwise a real frame that merely looks identical is suppressed from the trace,
// the recording and the verifier.
fn test_a_monitor_that_arrived_late_cannot_claim() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [0], '', false) // only monitor 0 existed
	if _ := r.claim(1, 'vcan0', f, 1) {
		assert false, 'a socket that did not exist yet claimed our emission'
	}
	c := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'the monitor that WAS there could not claim it'
		return
	}
	assert c.seq == 1
}

// Emissions made while nothing was watching — the sim's first frames, before the rx loops finish
// opening — are still OURS. Any monitor may claim them, because labelling our own traffic as the
// device under test's breaks the one promise the column makes.
fn test_an_emission_made_before_any_monitor_opened_is_still_ours() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [], '', false) // nobody watching yet
	c := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'our own frame was attributed to the device under test'
		return
	}
	assert c.seq == 1
}

// …but nobody was watching, so nothing can be called missing either.
fn test_an_unwatched_emission_is_never_reported_missing() {
	mut r := Ring{}
	r.note(1, 'vcan0', frame(0x120, [u8(1)]), 0, [], '', false)
	assert r.expire(default_window_ms + 1) == []u64{}, 'silence with no listener is not a fault'
}

// Eviction for room is not a verdict either: an unmonitored generator running flat out would
// otherwise mark its own healthy traffic as never having reached the wire.
fn test_eviction_reports_nothing_when_nobody_was_watching() {
	mut r := Ring{
		cap: 2
	}
	r.note(1, 'vcan0', frame(0x101, [u8(1)]), 0, [], '', false)
	r.note(2, 'vcan0', frame(0x102, [u8(2)]), 0, [], '', false)
	assert r.note(3, 'vcan0', frame(0x103, [u8(3)]), 0, [], '', false) == []u64{}
}

// Disabling a channel mid-run removes the only thing that could have confirmed our emissions.
// Marking them missing would accuse the bus of a fault the user caused by unticking a box.
fn test_removing_the_watcher_cancels_its_verdict() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [0], '', false)
	r.drop_monitor(0)
	assert r.expire(default_window_ms + 1) == []u64{}, 'a removed observer still produced a verdict'
}

// …and its record must not be claimable afterwards either. The socket is closed when the loop
// exits, so nothing will ever read that frame — while a channel disabled and re-enabled inside
// the window REUSES its monitor index, and that new socket never saw the emission. Letting it
// claim would credit a later echo to the old row and suppress a real frame as ours.
fn test_a_reused_monitor_index_cannot_claim_what_it_never_saw() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(2, 'vcan0', f, 0, [0], '', false)
	r.drop_monitor(0)
	if _ := r.claim(0, 'vcan0', f, 1) {
		assert false, 'a re-enabled monitor claimed an emission from before it existed'
	}
}

// An emission nobody was watching is different: no observer was ever named, so the first one to
// arrive may account for it — that is the startup window, and it is still OUR frame.
fn test_an_unwatched_emission_is_still_claimable() {
	mut r := Ring{}
	f := frame(0x121, [u8(1)])
	r.note(3, 'vcan0', f, 0, [], '', false)
	c := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'our own frame was attributed to the device under test'
		return
	}
	assert c.seq == 3
}

// With two monitors on one wire, one draining slower, capping the ring must not throw away a
// record the slow one has not reached — its copy of our own frame would arrive with nothing to
// match and be filed as the device under test's. Records everyone has answered go first.
fn test_capping_gives_up_settled_records_before_pending_ones() {
	mut r := Ring{
		cap: 2
	}
	a := frame(0x101, [u8(1)])
	b := frame(0x102, [u8(2)])
	r.note(1, 'vcan0', a, 0, [0, 1], '', false)
	r.note(2, 'vcan0', b, 0, [0, 1], '', false)
	// record 1 is fully accounted for; record 2 is still waiting on monitor 1
	r.claim(0, 'vcan0', a, 1) or { assert false, '${err}' }
	r.claim(1, 'vcan0', a, 1) or { assert false, '${err}' }
	r.claim(0, 'vcan0', b, 1) or { assert false, '${err}' }
	r.note(3, 'vcan0', frame(0x103, [u8(3)]), 1, [0, 1], '', false)
	// the settled one was dropped, so monitor 1's late copy of b can still be claimed
	c := r.claim(1, 'vcan0', b, 2) or {
		assert false, 'the slow monitor lost our frame to the cap'
		return
	}
	assert c.seq == 2
}

// A claim is evidence the frame reached the wire. Removing the monitor that made it must not
// delete that — otherwise a second, still-live monitor that never got its copy would let the
// record retire as missing, contradicting the one observation we actually have.
fn test_a_departing_monitor_leaves_its_evidence_behind() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [0, 1], '', false)
	r.claim(0, 'vcan0', f, 1) or {
		assert false, '${err}'
		return
	}
	r.drop_monitor(0) // that observer goes away, its claim stands
	assert r.expire(default_window_ms + 1) == []u64{}, 'a frame proven on the wire was called missing'
}

// A caller that already wrote the emission somewhere (its monitor had not published readiness
// yet, so it recorded at emit) must not have the echo write it a second time.
fn test_an_already_accounted_emission_says_so_on_claim() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [], '', true)
	c := r.claim(0, 'vcan0', f, 1) or {
		assert false, '${err}'
		return
	}
	assert c.done, 'the claim did not carry that the caller already handled it'
	assert c.first
}

// A monitor exiting must not touch emissions it was never eligible for. One noted while nothing
// was watching has an empty allowed set from the start, and that is the startup window — it has
// to stay claimable.
fn test_an_unrelated_monitor_leaving_does_not_close_the_startup_window() {
	mut r := Ring{}
	f := frame(0x120, [u8(1)])
	r.note(1, 'vcan0', f, 0, [], '', false) // nobody watching yet
	r.drop_monitor(3) // some other channel's loop exits
	c := r.claim(0, 'vcan0', f, 1) or {
		assert false, 'the startup window was closed by an unrelated monitor'
		return
	}
	assert c.seq == 1
}

// A flood of emissions nobody is watching must not push a WATCHED one out of the ring: dropping
// the unwatched costs nothing, while dropping the watched one reports it missing — one
// interface's traffic accusing another's healthy bus.
fn test_capping_gives_up_verdictless_records_before_watched_ones() {
	mut r := Ring{
		cap: 2
	}
	watched := frame(0x111, [u8(1)])
	r.note(1, 'vcan0', watched, 0, [0], '', false) // somebody is watching this one
	r.note(2, 'vcan1', frame(0x222, [u8(2)]), 0, [], '', false) // nobody is
	missed := r.note(3, 'vcan1', frame(0x333, [u8(3)]), 0, [], '', false)
	assert missed == []u64{}, 'an unwatched eviction produced a verdict: ${missed}'
	// the watched record survived, so its own echo can still claim it
	c := r.claim(0, 'vcan0', watched, 1) or {
		assert false, 'the watched emission was evicted by unwatched traffic'
		return
	}
	assert c.seq == 1
}

// An unwatched record is still CLAIMABLE — the startup window depends on it — so a settled one
// later in the ring must be given up first, even though the unwatched one is older.
fn test_a_settled_record_goes_before_an_older_unwatched_one() {
	mut r := Ring{
		cap: 2
	}
	un := frame(0x101, [u8(1)])
	st := frame(0x102, [u8(2)])
	r.note(1, 'vcan0', un, 0, [], '', false) // older, unwatched, still claimable
	r.note(2, 'vcan0', st, 0, [0], '', false)
	r.claim(0, 'vcan0', st, 1) or {
		assert false, '${err}'
		return
	} // now settled
	r.note(3, 'vcan0', frame(0x103, [u8(3)]), 1, [0], '', false)
	// the settled one was dropped; the older unwatched one survives and can still be claimed
	c := r.claim(0, 'vcan0', un, 2) or {
		assert false, 'the startup-window record was evicted before a settled one'
		return
	}
	assert c.seq == 1
}

// CAN-FD is a frame KIND, like extended vs standard. A classic frame carrying the same id and
// the same eight bytes is NOT the echo of our FD transmission — crediting it would mark one of
// ours confirmed by traffic that was never it, and hide a real ECU frame behind our own row.
fn test_a_classic_frame_is_not_the_echo_of_an_fd_one() {
	mut r := Ring{}
	fdf := transport.CanFrame{
		id:   0x100
		fd:   true
		data: [u8(1), 2, 3, 4, 5, 6, 7, 8]
	}
	classic := transport.CanFrame{
		id:   0x100
		data: [u8(1), 2, 3, 4, 5, 6, 7, 8]
	}
	r.note(1, 'vcan0', fdf, 0, [0], '', false)
	if _ := r.claim(0, 'vcan0', classic, 1) {
		assert false, 'a classic frame claimed an FD emission'
	}
	r.claim(0, 'vcan0', fdf, 1) or {
		assert false, 'the FD frame must claim its own echo'
		return
	}
}

// BRS likewise: two FD frames that differ only in the bit-rate-switch bit are different frames.
fn test_brs_is_part_of_the_identity() {
	mut r := Ring{}
	with := transport.CanFrame{
		id:   0x200
		fd:   true
		brs:  true
		data: [u8(9)]
	}
	without := transport.CanFrame{
		id:   0x200
		fd:   true
		data: [u8(9)]
	}
	r.note(2, 'vcan0', with, 0, [0], '', false)
	if _ := r.claim(0, 'vcan0', without, 1) {
		assert false, 'a non-BRS frame claimed a BRS emission'
	}
	r.claim(0, 'vcan0', with, 1) or {
		assert false, 'the BRS frame must claim its own echo'
		return
	}
}
