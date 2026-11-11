module isotp

fn test_first_frame_pci_and_length() {
	assert first_frame_pci(8) == [u8(0x10), 0x08]
	assert first_frame_pci(4095) == [u8(0x1F), 0xFF]
	assert first_frame_pci(4096) == [u8(0x10), 0x00, 0x00, 0x00, 0x10, 0x00]
	assert first_frame_pci(65535) == [u8(0x10), 0x00, 0x00, 0x00, 0xFF, 0xFF]
	for n in [8, 100, 4095, 4096, 5000, 65535] {
		mut f := first_frame_pci(n)
		f << []u8{len: 8 - f.len}
		got, pci := first_frame_length(f)!
		assert got == n
		assert pci == first_frame_pci(n).len
	}
	// past max_pdu is still read: the receiver answers it with OVERFLOW
	big, _ := first_frame_length([u8(0x10), 0, 0x12, 0x34, 0x56, 0x78, 0, 0])!
	assert big == 0x12345678
	// an escaped length the 12 bits give is refused
	if _, _ := first_frame_length([u8(0x10), 0, 0, 0, 0x0F, 0xFF, 0, 0]) {
		assert false, 'escaped 4095 taken'
	} else {
		assert err.msg().contains('12-bit form')
	}
}

fn test_transfer_wait_ms_scales_per_4095_bytes() {
	assert transfer_wait_ms(1000, 8) == 1000
	assert transfer_wait_ms(1000, 4095) == 1000
	assert transfer_wait_ms(1000, 4096) == 2000
	assert transfer_wait_ms(1000, max_pdu) == 17000
}
