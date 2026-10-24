module uds

import sync
import time
import blobly.isotp

// Kept is a client behind a lock, the way a binding holds one for a keep-alive.
@[heap]
struct Kept {
mut:
	mu  &sync.Mutex = sync.new_mutex()
	cli Client
}

fn (mut k Kept) host() KeepAliveHost {
	return KeepAliveHost{
		acquire: fn [mut k] () ?&Client {
			k.mu.lock()
			return &k.cli
		}
		release: fn [mut k] () {
			k.mu.unlock()
		}
	}
}

// a described node whose S3 is 400 ms, on `iface`; `table` names the services it serves
fn s3_node(iface string, services []ServiceSpec) (&isotp.SoftChannel, chan bool, thread) {
	mut ch := isotp.open_software(iface, 0x7C8, 0x7C0, false) or { panic(err) }
	stop := chan bool{cap: 1}
	srv := server_from(ServerSpec{
		dids:     [
			DidSpec{
				id:   0x0100
				data: [u8(7)]
				read: GateSpec{
					sessions: in_extended
				}
			},
		]
		table:    services.len > 0
		services: services
		s3_ms:    400
	})
	th := spawn serve_node(mut ch, srv, stop)
	return ch, stop, th
}

fn kept(iface string) &Kept {
	ch := isotp.open_software(iface, 0x7C0, 0x7C8, false) or { panic(err) }
	mut k := &Kept{}
	k.cli = new_client(ch)
	k.cli.serial = k.mu
	return k
}

// extended_read is the answer to reading the DID the extended session alone serves
fn extended_read(mut k Kept) []u8 {
	return k.cli.raw([u8(0x22), 0x01, 0x00]) or {
		if err is NegativeResponse {
			return [u8(0x7F), 0x22, err.nrc]
		}
		panic(err)
	}
}

fn test_without_a_keep_alive_the_session_lapses_at_s3() {
	_, stop, th := s3_node('inproc:KA1', [])
	defer {
		stop <- true
		th.wait()
	}
	mut k := kept('inproc:KA1')
	k.cli.diagnostic_session(0x03)!
	time.sleep(600 * time.millisecond)
	assert extended_read(mut k)[0] == 0x7F // back in the default session
}

fn test_a_keep_alive_holds_the_session_past_s3() {
	_, stop, th := s3_node('inproc:KA2', [])
	defer {
		stop <- true
		th.wait()
	}
	mut k := kept('inproc:KA2')
	k.cli.diagnostic_session(0x03)!
	before := k.cli.last
	count := k.cli.sent_count
	mut ka := keep_alive(250, k.host())!
	time.sleep(1100 * time.millisecond)
	st := ka.status()
	assert st.running && st.sent >= 2 && st.failures == 0, '${st}'
	// none of it is the client's own: its last exchange and count are the 0x10's
	k.mu.lock()
	assert k.cli.last == before && k.cli.sent_count == count
	k.mu.unlock()
	assert extended_read(mut k) == [u8(0x62), 0x01, 0x00, 7] // still extended
	assert ka.stop()
	assert !ka.status().running
}

fn test_nothing_is_sent_in_the_default_session_or_while_the_lock_is_held() {
	_, stop, th := s3_node('inproc:KA3', [])
	defer {
		stop <- true
		th.wait()
	}
	mut k := kept('inproc:KA3')
	mut ka := keep_alive(250, k.host())!
	time.sleep(400 * time.millisecond)
	assert ka.status().sent == 0 // no session answered yet
	k.cli.diagnostic_session(0x01)!
	time.sleep(400 * time.millisecond)
	assert ka.status().sent == 0 // the default session has no S3
	k.cli.diagnostic_session(0x03)!
	// held, as a request in progress holds it: nothing goes out inside it
	k.mu.lock()
	time.sleep(400 * time.millisecond)
	assert ka.status().sent == 0
	k.mu.unlock()
	time.sleep(300 * time.millisecond) // its send, and the window it listens in
	assert ka.status().sent == 1
	assert ka.stop()
}

fn test_a_refused_keep_alive_is_said_once_and_forgets_the_session() {
	// a node that serves 0x10 and 0x22, and not 0x3E
	_, stop, th := s3_node('inproc:KA4', [ServiceSpec{
		sid: 0x10
	}, ServiceSpec{
		sid: 0x22
	}])
	defer {
		stop <- true
		th.wait()
	}
	mut k := kept('inproc:KA4')
	k.cli.diagnostic_session(0x03)!
	mut ka := keep_alive(250, k.host())!
	time.sleep(700 * time.millisecond)
	st := ka.status()
	// one refusal, and nothing more: the session is no longer known
	assert st.failures == 1 && st.sent == 0, '${st}'
	assert st.failure.contains('refused')
	k.mu.lock()
	assert k.cli.state.session == 0
	k.mu.unlock()
	f := ka.take_failure() or { panic('no failure to take') }
	assert f.contains('0x11') || f.contains('refused')
	assert ka.take_failure() == none
	assert ka.stop()
}

fn test_the_keep_alive_rules() {
	assert !keepalive_due(0, 0, 10_000_000_000, 2000)
	assert !keepalive_due(default_session, 0, 10_000_000_000, 2000)
	assert keepalive_due(0x03, 0, 10_000_000_000, 2000)
	assert !keepalive_due(0x03, 1_000_000_000, 2_999_999_999, 2000)
	assert keepalive_due(0x03, 1_000_000_000, 3_000_000_000, 2000)
	assert keepalive_outcome(none) == .ok
	assert keepalive_outcome(NegativeResponse{ sid: 0x3E, nrc: 0x12 }) == .refused
	assert keepalive_outcome(PendingExpired{ sid: 0x3E }) == .pending
	assert keepalive_outcome(error('timeout')) == .failed
	keep_alive(keepalive_min_ms - 1, KeepAliveHost{
		acquire: fn () ?&Client {
			return none
		}
		release: fn () {}
	}) or { return }
	assert false, 'a period under the minimum was taken'
}

fn serve_node(mut ch isotp.SoftChannel, srv Server, stop chan bool) {
	mut s := srv
	s.serve(mut ch, stop)
	ch.close()
}
