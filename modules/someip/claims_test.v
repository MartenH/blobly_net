module someip

// The overlap rule is the kernel's, not a string comparison.
fn test_overlap_is_the_kernels_rule() {
	assert overlaps('0.0.0.0', 30491, '127.0.0.1', 30491), 'a wildcard covers every address on its port'
	// overlaps() takes CANONICAL hosts: '' never reaches it, canonical_host having already made
	// it the v4 wildcard.
	assert overlaps('127.0.0.1', 30491, '0.0.0.0', 30491)
	assert overlaps('127.0.0.1', 30491, '127.0.0.1', 30491)
	assert !overlaps('127.0.0.1', 30491, '192.168.0.5', 30491), 'two NICs, two listeners, no overlap'
	assert !overlaps('0.0.0.0', 30491, '0.0.0.0', 30492), 'different ports never overlap'
}

// A claim refuses the second listener and names the first, whichever order they arrive in.
fn test_a_claim_refuses_the_second_and_names_the_first() {
	_ := claim_endpoint('0.0.0.0', 39001, 'channel ETH1', .row)!
	if _ := claim_endpoint('127.0.0.1', 39001, 'a script', .row) {
		assert false, 'an overlapping claim was accepted'
	} else {
		assert err.msg().contains('channel ETH1'), err.msg()
		assert err.msg().contains('SPLIT'), err.msg()
	}
	// a different port is free
	_ := claim_endpoint('0.0.0.0', 39002, 'a script', .row)!
	release_endpoint('0.0.0.0', 39001, 'channel ETH1')
	// and once released, the endpoint is claimable again — the reverse ordering
	_ := claim_endpoint('127.0.0.1', 39001, 'a script', .row)!
	release_endpoint('127.0.0.1', 39001, 'a script')
	release_endpoint('0.0.0.0', 39002, 'a script')
}

// Releasing something never claimed is a no-op, so a caller may release on every exit path.
fn test_release_of_an_unheld_claim_is_a_noop() {
	release_endpoint('0.0.0.0', 39003, 'nobody')
	_ := claim_endpoint('0.0.0.0', 39003, 'channel ETH9', .row)!
	release_endpoint('0.0.0.0', 39003, 'someone else') // wrong owner: leaves it held
	if _ := claim_endpoint('0.0.0.0', 39003, 'a script', .row) {
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
	_ := claim_endpoint(real, 39010, 'channel ETH1', .row)!
	for spelling in ['localhost', 'LOCALHOST', 'localhost '] {
		if _ := claim_endpoint(spelling, 39010, 'a script', .row) {
			release_endpoint(spelling, 39010, 'a script')
			assert false, '"${spelling}" was accepted beside ${real}'
		} else {
			assert err.msg().contains('channel ETH1'), err.msg()
		}
	}
	// Released by the value the claim RETURNED, which is the contract: re-resolving a spelling
	// here is what could strand a claim when an answer changes.
	release_endpoint(real, 39010, 'channel ETH1')
	again := claim_endpoint('localhost', 39010, 'a script', .script)!
	release_endpoint(again, 39010, 'a script')
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
	// '::' stays itself: dual-stack, so it covers BOTH families where 0.0.0.0 covers one
	assert canonical_host('::') == '::'
	assert canonical_host('[::]') == '::'
	// a name that cannot resolve keeps its spelling: the bind reports it, not the claim
	assert canonical_host('no-such-host.invalid') == 'no-such-host.invalid'
}

// A v4 wildcard and a v6 address are two disjoint listeners, which Linux is happy to have at
// once; `::` is dual-stack in this V, so it covers both.
fn test_wildcards_keep_their_families() {
	assert !overlaps('0.0.0.0', 1, '::1', 1), 'the v4 wildcard receives nothing sent to a v6 address'
	assert overlaps('0.0.0.0', 1, '127.0.0.1', 1)
	assert overlaps('::', 1, '127.0.0.1', 1), 'V enables dual-stack on its v6 sockets'
	assert overlaps('::', 1, '::1', 1)
	assert !overlaps('::1', 1, '127.0.0.1', 1)
	assert !overlaps('0.0.0.0', 1, '0.0.0.0', 2), 'different ports never overlap'
}

// The refusal says WHO and WHAT SORT, so a caller can wait for a departing row and refuse a
// live script without parsing a sentence.
fn test_the_refusal_carries_the_holder() {
	canon := claim_endpoint('127.0.0.1', 39020, 'a script', .script)!
	if _ := claim_endpoint('127.0.0.1', 39020, 'channel ETH1', .row) {
		assert false, 'an overlapping claim was accepted'
	} else {
		assert err is ClaimHeld, err.msg()
		if err is ClaimHeld {
			assert err.kind == .script
			assert err.owner == 'a script'
		}
	}
	release_endpoint(canon, 39020, 'a script')
}

// A claim is released by the value the claim RETURNED, so a changed DNS answer cannot strand it.
fn test_released_by_the_canonical_value() {
	canon := claim_endpoint('localhost', 39021, 'channel ETH1', .row)!
	release_endpoint(canon, 39021, 'channel ETH1')
	second := claim_endpoint('localhost', 39021, 'a script', .script)!
	release_endpoint(second, 39021, 'a script')
}
