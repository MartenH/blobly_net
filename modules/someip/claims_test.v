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
