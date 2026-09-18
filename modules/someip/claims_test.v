module someip

// The overlap rule is the kernel's, not a string comparison.
fn test_overlap_is_the_kernels_rule() {
	assert overlaps('0.0.0.0', 30491, '127.0.0.1', 30491), 'a wildcard covers every address on its port'
	assert overlaps('127.0.0.1', 30491, '', 30491), 'an empty host IS the wildcard'
	assert overlaps('127.0.0.1', 30491, '127.0.0.1', 30491)
	assert !overlaps('127.0.0.1', 30491, '192.168.0.5', 30491), 'two NICs, two listeners, no overlap'
	assert !overlaps('0.0.0.0', 30491, '0.0.0.0', 30492), 'different ports never overlap'
}

// A claim refuses the second listener and names the first, whichever order they arrive in.
fn test_a_claim_refuses_the_second_and_names_the_first() {
	claim_endpoint('0.0.0.0', 39001, 'channel ETH1')!
	if _ := claim_endpoint('127.0.0.1', 39001, 'a script') {
		assert false, 'an overlapping claim was accepted'
	} else {
		assert err.msg().contains('channel ETH1'), err.msg()
		assert err.msg().contains('SPLIT'), err.msg()
	}
	// a different port is free
	claim_endpoint('0.0.0.0', 39002, 'a script')!
	release_endpoint('0.0.0.0', 39001, 'channel ETH1')
	// and once released, the endpoint is claimable again — the reverse ordering
	claim_endpoint('127.0.0.1', 39001, 'a script')!
	release_endpoint('127.0.0.1', 39001, 'a script')
	release_endpoint('0.0.0.0', 39002, 'a script')
}

// Releasing something never claimed is a no-op, so a caller may release on every exit path.
fn test_release_of_an_unheld_claim_is_a_noop() {
	release_endpoint('0.0.0.0', 39003, 'nobody')
	claim_endpoint('0.0.0.0', 39003, 'channel ETH9')!
	release_endpoint('0.0.0.0', 39003, 'someone else') // wrong owner: leaves it held
	if _ := claim_endpoint('0.0.0.0', 39003, 'a script') {
		assert false, 'a wrong-owner release dropped the claim'
	}
	release_endpoint('0.0.0.0', 39003, 'channel ETH9')
}

// Two spellings of one address are one endpoint. Comparing the strings accepted both claims and
// let the kernel split the stream between them — a synonym defeating the whole registry.
//
// ASKED OF THIS MACHINE, not of a hardcoded pair: `localhost` is 127.0.0.1 on most hosts and ::1
// on some (the CI runner is one), and on those it is genuinely a different socket from
// 127.0.0.1. So the test claims whatever `localhost` actually resolves to and requires THAT to
// collide, which is the property the registry owes on every machine. A hardcoded pair asserted
// the resolver's configuration instead, and failed on the first host that differed.
fn test_a_synonym_is_not_a_second_endpoint() {
	real := canonical_host('localhost')
	claim_endpoint(real, 39010, 'channel ETH1')!
	for spelling in ['localhost', 'LOCALHOST', 'localhost '] {
		if _ := claim_endpoint(spelling, 39010, 'a script') {
			release_endpoint(spelling, 39010, 'a script')
			assert false, '"${spelling}" was accepted beside ${real}'
		} else {
			assert err.msg().contains('channel ETH1'), err.msg()
		}
	}
	release_endpoint('LOCALHOST', 39010, 'channel ETH1') // released by any spelling of it
	claim_endpoint('localhost', 39010, 'a script')!
	release_endpoint(real, 39010, 'a script')
}

// Case and surrounding space are never a second endpoint, on any machine.
fn test_case_and_space_fold() {
	assert canonical_host('LOCALHOST') == canonical_host('localhost')
	assert canonical_host(' localhost ') == canonical_host('localhost')
	assert canonical_host('[::1]') == canonical_host('::1')
}

fn test_canonical_host_answers_the_wildcard_without_resolving() {
	assert canonical_host('') == '0.0.0.0'
	assert canonical_host('0.0.0.0') == '0.0.0.0'
	assert canonical_host('::') == '0.0.0.0'
	// a name that cannot resolve keeps its spelling: the bind reports it, not the claim
	assert canonical_host('no-such-host.invalid') == 'no-such-host.invalid'
}
