module uds

fn test_standard_did_names() {
	assert standard_did_name(0xF190) == 'VIN'
	assert standard_did_name(0xF18C) == 'ECU serial number'
	assert standard_did_name(0xF1A0) == '' // the manufacturer's range
	assert standard_did_name(0x0102) == ''
}

fn test_ext_record_names_cover_the_sized_records() {
	for n, _ in blobly_ext_records {
		assert blobly_ext_record_name(n) != ''
	}
	assert blobly_ext_record_name(0x04) == ''
}

fn test_status_bit_abbreviations_are_the_iso_ones() {
	assert dtc_status_bits.map(it.abbrev()) == ['TF', 'TFTOC', 'PDTC', 'CDTC', 'TNCSLC', 'TFSLC',
		'TNCTOC', 'WIR']
	assert status_abbrevs(0x2F) == ['TF', 'TFTOC', 'PDTC', 'CDTC', 'TFSLC']
}
