module transport

import time

// The retry around a CANsub TLS connect is only for a handshake a signal interrupted. These pin
// the classifier against the exact error V's SSLConn.connect produces, and the loop's control
// flow — the part a later edit can quietly break — driven with an injected connect.

fn interrupted() IError {
	return error_with_code('net.mbedtls SSLConn.connect, mbedtls_ssl_handshake failed 2; ret: -26880',
		-26880)
}

fn test_interrupted_is_want_read_on_a_handshake_only() {
	assert cansub_handshake_interrupted(interrupted())
	// Interrupted while SENDING: mbedtls maps that EINTR to WANT_WRITE (codex on #264).
	assert cansub_handshake_interrupted(error_with_code('net.mbedtls SSLConn.connect, mbedtls_ssl_handshake failed 2; ret: -26752',
		-26752))
	// The same text without the code still qualifies (a wrapper that kept only the message).
	assert cansub_handshake_interrupted(error('net.mbedtls SSLConn.connect, mbedtls_ssl_handshake failed 2; ret: -26880'))
	// A handshake that FAILED (a real TLS error) is not an interruption.
	assert !cansub_handshake_interrupted(error_with_code('net.mbedtls SSLConn.connect, mbedtls_ssl_handshake failed 2; ret: -30592',
		-30592))
	// A read timeout is not one either: the device really did not answer.
	assert !cansub_handshake_interrupted(error_with_code('net.mbedtls SSLConn.connect, mbedtls_ssl_handshake failed 2; ret: -26624',
		-26624))
	// The code alone, on an unrelated error, does not qualify.
	assert !cansub_handshake_interrupted(error_with_code('connection refused', -26880))
	assert !cansub_handshake_interrupted(error('cannot resolve e5a16adf-usb.local'))
}

// A closure captures by value, so the call count lives behind a pointer the closure copies.
struct Calls {
mut:
	n int
}

fn test_second_try_after_one_interruption_succeeds() {
	mut calls := &Calls{}
	got := cansub_connect_attempts[int](time.now().add(time.second), fn [mut calls] () !int {
		calls.n++
		if calls.n == 1 {
			return interrupted()
		}
		return 42
	}) or {
		assert false, 'one interruption must be survived: ${err}'
		return
	}
	assert got == 42
	assert calls.n == 2
}

fn test_any_other_error_ends_it_at_once() {
	mut calls := &Calls{}
	cansub_connect_attempts[int](time.now().add(time.second), fn [mut calls] () !int {
		calls.n++
		return error('connection refused')
	}) or {
		assert err.msg() == 'connection refused'
		assert calls.n == 1
		return
	}
	assert false, 'a refused connect must not be retried'
}

fn test_gives_up_after_the_tries_with_the_last_error() {
	mut calls := &Calls{}
	cansub_connect_attempts[int](time.now().add(time.second), fn [mut calls] () !int {
		calls.n++
		return interrupted()
	}) or {
		assert calls.n == cansub_connect_tries
		assert err.msg().contains('mbedtls_ssl_handshake')
		assert err.msg().contains('interrupted on every try')
		return
	}
	assert false, 'a handshake interrupted every time must fail'
}

fn test_a_passed_deadline_stops_the_retry() {
	mut calls := &Calls{}
	cansub_connect_attempts[int](time.now().add(-time.second), fn [mut calls] () !int {
		calls.n++
		return interrupted()
	}) or {
		assert calls.n == 1
		return
	}
	assert false, 'no retry past the deadline'
}
