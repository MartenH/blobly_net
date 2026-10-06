module uds

// did_names.v — what a data identifier or an extended data record is called when nothing more
// specific says: the identifiers ISO 14229-1 Annex C.1 standardises, and blobly_emb's extended data
// records. A description file (sysview.EcuDesc) names a node's own DIDs; these are the fallback
// every tester can show without one.

// standard_did_name: the ISO 14229-1 Annex C.1 name of `id`, or '' for one the standard leaves to
// the manufacturer.
pub fn standard_did_name(id u16) string {
	return match id {
		0xF180 { 'boot software identification' }
		0xF181 { 'application software identification' }
		0xF182 { 'application data identification' }
		0xF183 { 'boot software fingerprint' }
		0xF184 { 'application software fingerprint' }
		0xF185 { 'application data fingerprint' }
		0xF186 { 'active diagnostic session' }
		0xF187 { 'spare part number' }
		0xF188 { 'ECU software number' }
		0xF189 { 'ECU software version' }
		0xF18A { 'system supplier identifier' }
		0xF18B { 'ECU manufacturing date' }
		0xF18C { 'ECU serial number' }
		0xF18D { 'supported functional units' }
		0xF18E { 'kit assembly part number' }
		0xF190 { 'VIN' }
		0xF191 { 'ECU hardware number' }
		0xF192 { 'supplier ECU hardware number' }
		0xF193 { 'supplier ECU hardware version' }
		0xF194 { 'supplier ECU software number' }
		0xF195 { 'supplier ECU software version' }
		0xF196 { 'exhaust regulation type approval number' }
		0xF197 { 'system name' }
		0xF198 { 'repair shop code' }
		0xF199 { 'programming date' }
		0xF19A { 'calibration repair shop code' }
		0xF19B { 'calibration date' }
		0xF19C { 'calibration equipment software number' }
		0xF19D { 'ECU installation date' }
		0xF19E { 'ODX file' }
		0xF19F { 'entity' }
		else { '' }
	}
}

// blobly_ext_record_name: what blobly_emb's extended data record `number` counts
// (blobly_ext_records sizes them), or '' for one it does not define.
pub fn blobly_ext_record_name(number u8) string {
	return match number {
		0x01 { 'occurrences' }
		0x02 { 'aging' }
		0x03 { 'failed cycles' }
		else { '' }
	}
}
