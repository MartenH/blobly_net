// nm — CAN network management, the READ side: who reports in on a bus's NM cluster and who
// keeps the network awake. It listens and sends nothing.
//
// The PDU is blobly_emb's comm/nm frame (its docs/nm.md is the reference), which keeps AUTOSAR
// CanNm's default byte positions:
//
//   byte 0     the source node id (NID)
//   byte 1     the Control Bit Vector (CBV): bit 0 repeat-message request, bit 3 ready-to-sleep
//              (the sender has released the network), bit 4 active wake-up, bit 6 PN info
//   bytes 2..7 the partial-network request mask, little-endian, meaningful only with PN info
//
// Bit 3 is read as blobly_emb sends it: a node that has released the network says so and goes
// on announcing. In AUTOSAR CanNm that bit is the coordinator's sleep-ready bit, and a node
// releases by falling silent — which reads here as silence past the timeout, so an AUTOSAR
// cluster goes from awake to asleep without passing through releasing.
//
// A node announces on its own CAN id in the cluster's NM range. Nothing here decides that a
// frame IS an NM PDU: the range comes from a configuration (config.v), and a wire with none has
// no NM reading at all.
module nm

pub const cbv_repeat_request = u8(0x01)
pub const cbv_ready_to_sleep = u8(0x08)
pub const cbv_active_wakeup = u8(0x10)
pub const cbv_pn_info = u8(0x40)

// Pdu is one decoded NM PDU.
pub struct Pdu {
pub:
	nid    u8
	cbv    u8
	pn     u64 // the partial-network request mask (bytes 2..7); 0 unless has_pn
	has_pn bool
}

// parse decodes an NM PDU. A frame shorter than 2 bytes carries no CBV and is refused, and so
// is one whose CBV says PN info with no mask byte after it. The mask is read from the bytes
// present, up to byte 7.
pub fn parse(data []u8) !Pdu {
	if data.len < 2 {
		return error('${data.len}-byte NM PDU: the node id and the control bit vector need 2')
	}
	cbv := data[1]
	if cbv & cbv_pn_info == 0 {
		return Pdu{
			nid: data[0]
			cbv: cbv
		}
	}
	if data.len < 3 {
		return error('NM PDU of node 0x${data[0]:02X} says PN info and carries no mask byte')
	}
	mut pn := u64(0)
	end := if data.len < 8 { data.len } else { 8 }
	for i in 2 .. end {
		pn |= u64(data[i]) << (8 * u64(i - 2))
	}
	return Pdu{
		nid:    data[0]
		cbv:    cbv
		pn:     pn
		has_pn: true
	}
}

// ready_to_sleep: the sender has released the network.
pub fn (p Pdu) ready_to_sleep() bool {
	return p.cbv & cbv_ready_to_sleep != 0
}

// phase is what the sender says about the network: requesting it, or ready to sleep.
pub fn (p Pdu) phase() Phase {
	return if p.ready_to_sleep() { .ready } else { .requesting }
}

// bit_words names a CBV's meaningful bits in words, the network request first.
pub fn bit_words(cbv u8) []string {
	mut out := []string{}
	out << if cbv & cbv_ready_to_sleep != 0 { 'ready to sleep' } else { 'wants network' }
	if cbv & cbv_active_wakeup != 0 {
		out << 'active wake-up'
	}
	if cbv & cbv_repeat_request != 0 {
		out << 'repeat request'
	}
	return out
}

// Phase is a node's state at one moment, ordered so the greater of two is the one a timeline
// column shows: requesting beats ready, ready beats silent.
pub enum Phase {
	silent
	ready
	requesting
}
